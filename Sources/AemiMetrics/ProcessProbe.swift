#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

/// Low-overhead, dependency-free probes for a process's own CPU and memory usage — the building block
/// for "how much did *this* cost" measurements around a method, a phase, or a whole run.
///
/// Everything reads the calling process via stdlib + libc/Mach syscalls only (no Foundation, no
/// external package), so it composes into any tier — benchmarks, tests, an ad-hoc timing harness, or a
/// server's own telemetry. Take a ``snapshot()`` before and after the work and ``delta(from:to:)`` (or
/// just ``measure(_:)``) to get the cost of exactly that interval.
///
/// **Why deltas, not absolutes.** Whole-process resident memory is dominated by a baseline (the
/// runtime, loaded code, retained data), so an absolute reading says little about one operation.
/// Bracketing an interval and diffing the snapshots isolates *its* cost. For allocation pressure
/// specifically, prefer an allocator counter (jemalloc's `thread.allocated`) where available — see the
/// type's documentation note — since allocation count is baseline-independent.
///
/// **Metric meanings.**
/// - `wallNanos` — monotonic elapsed time (`CLOCK_MONOTONIC`); includes time spent off-CPU.
/// - `processCPUNanos` — user + system CPU consumed by all threads (`getrusage(RUSAGE_SELF)`).
/// - `threadCPUNanos` — CPU consumed by the *calling thread* (`CLOCK_THREAD_CPUTIME_ID`).
/// - `residentBytes` — current resident set size (Mach `MACH_TASK_BASIC_INFO` / Linux `/proc`).
/// - `footprintBytes` — Apple's `phys_footprint` (what the memory limit / Jetsam use); on Linux there
///   is no equivalent, so it mirrors `residentBytes`.
/// - `instructions` / `cycles` — retired instructions and CPU cycles for the process, the most
///   reproducible CPU metric (immune to frequency scaling). Apple Silicon only via
///   `proc_pid_rusage`; `0` where the platform/CPU does not report them.
public enum ProcessProbe {
    /// A point-in-time reading of the process's CPU and memory counters. Diff two with
    /// ``delta(from:to:)`` to attribute the change to the interval between them.
    public struct Snapshot: Sendable, Equatable {
        public var wallNanos: UInt64
        public var processCPUNanos: UInt64
        public var threadCPUNanos: UInt64
        public var residentBytes: UInt64
        public var footprintBytes: UInt64
        public var instructions: UInt64
        public var cycles: UInt64
    }

    /// The change between two ``Snapshot``s. Time and counter fields are non-negative durations;
    /// memory fields are signed because a resident/footprint figure can fall as well as rise.
    public struct Delta: Sendable, Equatable {
        public var wallNanos: UInt64
        public var processCPUNanos: UInt64
        public var threadCPUNanos: UInt64
        public var residentBytesDelta: Int64
        public var footprintBytesDelta: Int64
        public var instructions: UInt64
        public var cycles: UInt64
    }

    /// Capture every counter at once. Wall time is read last so it brackets the cheaper reads as
    /// tightly as possible.
    public static func snapshot() -> Snapshot {
        let cpu = processCPUNanos()
        let thread = threadCPUNanos()
        let resident = residentBytes()
        let footprint = footprintBytes()
        let (instructions, cycles) = instructionsAndCycles()
        return Snapshot(
            wallNanos: monotonicNanos(),
            processCPUNanos: cpu.user &+ cpu.system,
            threadCPUNanos: thread,
            residentBytes: resident,
            footprintBytes: footprint,
            instructions: instructions,
            cycles: cycles)
    }

    /// The change from `a` to `b`. Counter fields use wrapping subtraction (monotonic, so the result
    /// is the true increase); memory deltas are reinterpreted as signed so a decrease reads negative.
    public static func delta(from a: Snapshot, to b: Snapshot) -> Delta {
        Delta(
            wallNanos: b.wallNanos &- a.wallNanos,
            processCPUNanos: b.processCPUNanos &- a.processCPUNanos,
            threadCPUNanos: b.threadCPUNanos &- a.threadCPUNanos,
            residentBytesDelta: Int64(bitPattern: b.residentBytes &- a.residentBytes),
            footprintBytesDelta: Int64(bitPattern: b.footprintBytes &- a.footprintBytes),
            instructions: b.instructions &- a.instructions,
            cycles: b.cycles &- a.cycles)
    }

    /// Run `body`, returning its result alongside the CPU/memory cost of the call. The probe overhead
    /// (two ``snapshot()`` reads) is charged to the interval, so treat very short measurements as
    /// dominated by it — measure a loop, or amortize over many iterations.
    @discardableResult
    public static func measure<R>(_ body: () throws -> R) rethrows -> (delta: Delta, result: R) {
        let start = snapshot()
        let result = try body()
        let end = snapshot()
        return (delta(from: start, to: end), result)
    }

    // MARK: - Individual counters

    /// Monotonic wall-clock nanoseconds (`CLOCK_MONOTONIC`). Only differences are meaningful.
    public static func monotonicNanos() -> UInt64 {
        var ts = timespec()
        _ = clock_gettime(CLOCK_MONOTONIC, &ts)
        return UInt64(ts.tv_sec) &* 1_000_000_000 &+ UInt64(ts.tv_nsec)
    }

    /// CPU nanoseconds consumed by the calling thread only (`CLOCK_THREAD_CPUTIME_ID`).
    public static func threadCPUNanos() -> UInt64 {
        var ts = timespec()
        _ = clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
        return UInt64(ts.tv_sec) &* 1_000_000_000 &+ UInt64(ts.tv_nsec)
    }

    /// User and system CPU nanoseconds for the whole process (all threads), via `getrusage`.
    public static func processCPUNanos() -> (user: UInt64, system: UInt64) {
        let ru = selfUsage()
        return (timevalNanos(ru.ru_utime), timevalNanos(ru.ru_stime))
    }

    /// Peak resident set size in bytes since the process started (`getrusage` high-water mark).
    /// Normalized to bytes on every platform (Darwin reports bytes, Linux reports kilobytes).
    public static func peakResidentBytes() -> UInt64 {
        let ru = selfUsage()
        #if canImport(Darwin)
            return UInt64(clamping: ru.ru_maxrss)
        #else
            return UInt64(clamping: ru.ru_maxrss) &* 1024
        #endif
    }

    /// `getrusage(RUSAGE_SELF)` with the `who` argument spelled per libc. Darwin (and Musl) declare
    /// the parameter `Int32` and export `RUSAGE_SELF` to match, but Glibc's importer vends
    /// `RUSAGE_SELF` as the C enum `__rusage_who` while `getrusage` still takes a plain `Int32`,
    /// so the raw value must be passed explicitly there.
    private static func selfUsage() -> rusage {
        var ru = rusage()
        #if canImport(Glibc)
            _ = getrusage(RUSAGE_SELF.rawValue, &ru)
        #else
            _ = getrusage(RUSAGE_SELF, &ru)
        #endif
        return ru
    }

    @inline(__always)
    private static func timevalNanos(_ tv: timeval) -> UInt64 {
        UInt64(clamping: tv.tv_sec) &* 1_000_000_000 &+ UInt64(clamping: tv.tv_usec) &* 1000
    }

    #if canImport(Darwin)

        /// Current resident size in bytes — Mach `MACH_TASK_BASIC_INFO.resident_size`.
        public static func residentBytes() -> UInt64 {
            var info = mach_task_basic_info()
            var count = mach_msg_type_number_t(
                MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
            let kr = withUnsafeMutablePointer(to: &info) { ptr in
                ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
                }
            }
            return kr == KERN_SUCCESS ? UInt64(clamping: info.resident_size) : 0
        }

        /// Apple's physical memory footprint in bytes — Mach `TASK_VM_INFO.phys_footprint`, the figure
        /// the memory-limit system and Xcode's gauge report. This is the number to watch on Apple
        /// platforms; `residentBytes()` is the raw RSS beneath it.
        public static func footprintBytes() -> UInt64 {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(
                MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            let kr = withUnsafeMutablePointer(to: &info) { ptr in
                ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            return kr == KERN_SUCCESS ? UInt64(clamping: info.phys_footprint) : 0
        }

        /// Retired instructions and CPU cycles for the process (`proc_pid_rusage`, `RUSAGE_INFO_V4`).
        /// Populated on Apple Silicon; `(0, 0)` where the hardware counters are unavailable.
        public static func instructionsAndCycles() -> (instructions: UInt64, cycles: UInt64) {
            var info = rusage_info_v4()
            let kr = withUnsafeMutablePointer(to: &info) { ptr in
                ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
                }
            }
            return kr == 0 ? (info.ri_instructions, info.ri_cycles) : (0, 0)
        }

    #else

        /// Current resident size in bytes — `/proc/self/statm` resident pages × page size.
        public static func residentBytes() -> UInt64 {
            let pageSize = UInt64(clamping: sysconf(Int32(_SC_PAGESIZE)))
            return statmResidentPages() &* pageSize
        }

        /// Linux has no `phys_footprint` analogue; the resident set is the closest equivalent.
        public static func footprintBytes() -> UInt64 { residentBytes() }

        /// Hardware instruction/cycle counts are not read here on Linux (they require `perf_event_open`
        /// and elevated permissions). Use `perf stat` externally; this returns `(0, 0)`.
        public static func instructionsAndCycles() -> (instructions: UInt64, cycles: UInt64) { (0, 0) }

        /// The second whitespace-separated field of `/proc/self/statm` (resident pages).
        private static func statmResidentPages() -> UInt64 {
            let fd = open("/proc/self/statm", O_RDONLY)
            guard fd >= 0 else { return 0 }
            defer { close(fd) }
            var buffer = [UInt8](repeating: 0, count: 128)
            let bytesRead = buffer.withUnsafeMutableBytes { raw in
                read(fd, raw.baseAddress, raw.count)
            }
            guard bytesRead > 0 else { return 0 }
            var field = 0
            var value: UInt64 = 0
            var inDigits = false
            for i in 0 ..< Int(bytesRead) {
                let byte = buffer[i]
                if byte >= 0x30 && byte <= 0x39 {
                    value = value &* 10 &+ UInt64(byte - 0x30)
                    inDigits = true
                } else if inDigits {
                    if field == 1 { return value }  // field 0 = total size, field 1 = resident
                    field += 1
                    value = 0
                    inDigits = false
                }
            }
            return field == 1 ? value : 0
        }

    #endif
}

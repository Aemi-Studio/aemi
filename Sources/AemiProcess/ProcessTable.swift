#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

/// The processes of a user: who they are, which session and group they belong to, when they started, their
/// environment, and what they use. The building block for supervising children wherever they went (ADR 0028).
///
/// A supervisor that kills a child's process group misses the processes that left it: `swift test` starts its testing
/// helper in a new group, and a test host on a simulator is started by the simulator, not by the supervisor. Two keys
/// still find them: the session (a new group keeps the session; only `setsid` leaves it), and an environment entry the
/// supervisor put there, which every descendant inherits.
///
/// - Darwin reads `sysctl(KERN_PROC_UID)`, `KERN_PROCARGS2` and `proc_pid_rusage`. macOS hides the environment of
///   Apple platform binaries (`/bin/sleep`, `/usr/bin/perl`, measured on macOS 27), so ``environment(of:)`` is empty
///   for them; their session still finds them.
/// - Linux reads `/proc`.
///
/// Every call is a snapshot: a process may exit, or its pid be reused, right after it is listed. ``Process/started``
/// tells a reused pid from the process that was listed.
public enum ProcessTable {
    /// One process, as listed.
    public struct Process: Sendable, Hashable {
        public let pid: Int32
        public let parent: Int32
        public let group: Int32
        public let session: Int32
        /// When it started, in microseconds since 1970; with the pid, it identifies the process.
        public let started: Int64

        public init(pid: Int32, parent: Int32, group: Int32, session: Int32, started: Int64) {
            self.pid = pid
            self.parent = parent
            self.group = group
            self.session = session
            self.started = started
        }
    }

    /// What a live process has used so far.
    public struct Usage: Sendable, Equatable {
        public var userNanoseconds: UInt64
        public var systemNanoseconds: UInt64
        public var residentBytes: UInt64
        /// Apple's `phys_footprint` (what the memory limits use); the resident size on Linux.
        public var footprintBytes: UInt64
        /// The highest footprint over the process's life (Darwin `ri_lifetime_max_phys_footprint`, Linux `VmHWM`).
        public var peakFootprintBytes: UInt64

        public init(
            userNanoseconds: UInt64,
            systemNanoseconds: UInt64,
            residentBytes: UInt64,
            footprintBytes: UInt64,
            peakFootprintBytes: UInt64
        ) {
            self.userNanoseconds = userNanoseconds
            self.systemNanoseconds = systemNanoseconds
            self.residentBytes = residentBytes
            self.footprintBytes = footprintBytes
            self.peakFootprintBytes = peakFootprintBytes
        }

        public var cpuNanoseconds: UInt64 { userNanoseconds &+ systemNanoseconds }
    }

    /// The real user id of the calling process.
    public static var currentUser: UInt32 { UInt32(getuid()) }

    /// The processes of `user` (the caller's by default), the caller included. Empty when the table cannot be read.
    public static func list(user: UInt32 = currentUser) -> [Process] {
        platformList(user: user)
    }

    /// The members of `session`, other than the caller.
    public static func members(ofSession session: Int32, user: UInt32 = currentUser) -> [Process] {
        let me = getpid()
        return list(user: user).filter { $0.session == session && $0.pid != me }
    }

    /// The session of `pid`, or nil when it does not exist.
    public static func session(of pid: Int32) -> Int32? {
        let session = getsid(pid)
        return session < 0 ? nil : session
    }

    /// The environment of `pid`, `NAME=value` strings in order; nil when it cannot be read, empty when the platform
    /// hides it (Apple platform binaries).
    public static func environment(of pid: Int32) -> [String]? {
        guard let bytes = platformEnvironmentBytes(of: pid) else { return nil }
        return bytes.split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Whether the environment of `pid` holds exactly `entry` (`NAME=value`). False when it cannot be read.
    public static func environment(of pid: Int32, contains entry: String) -> Bool {
        guard let bytes = platformEnvironmentBytes(of: pid) else { return false }
        let wanted = Array(entry.utf8)
        return bytes.split(separator: 0, omittingEmptySubsequences: true).contains { $0.elementsEqual(wanted) }
    }

    /// What `pid` has used so far, or nil when it cannot be read (gone, or another user's).
    public static func usage(of pid: Int32) -> Usage? {
        platformUsage(of: pid)
    }

    /// Sends `signal` to `pid`; true when it was delivered.
    @discardableResult
    public static func send(_ signal: Int32, to pid: Int32) -> Bool {
        kill(pid, signal) == 0
    }

    /// Reads a `KERN_PROCARGS2` record (argc, executable path, padding, argc arguments, then the environment, each
    /// NUL-terminated) and returns the environment block: its strings, NUL-separated. Empty when there is none.
    static func environmentBlock(procargs: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
        guard procargs.count > 4 else { return [] }
        let start = procargs.startIndex
        let argc =
            Int(procargs[start]) | Int(procargs[start + 1]) << 8 | Int(procargs[start + 2]) << 16
            | Int(procargs[start + 3]) << 24
        var index = start + 4
        while index < procargs.endIndex, procargs[index] != 0 { index += 1 }  // executable path
        while index < procargs.endIndex, procargs[index] == 0 { index += 1 }  // padding
        for _ in 0 ..< argc {
            while index < procargs.endIndex, procargs[index] != 0 { index += 1 }
            index += 1
            guard index < procargs.endIndex else { return [] }
        }
        // The environment: NUL-terminated strings up to the first empty one.
        let block = index
        while index < procargs.endIndex, procargs[index] != 0 {
            while index < procargs.endIndex, procargs[index] != 0 { index += 1 }
            index += 1
        }
        return procargs[block ..< min(index, procargs.endIndex)]
    }
}

#if canImport(Darwin)
    extension ProcessTable {
        static func platformList(user: UInt32) -> [Process] {
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: user)]
            for _ in 0 ..< 4 {
                var size = 0
                // SAFETY: a nil buffer only asks for the size; `mib` is a live local array.
                guard unsafe sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
                size += size / 8
                // SAFETY: kinfo_proc is a C record with kernel pointers; they are never dereferenced.
                let stride = unsafe MemoryLayout<kinfo_proc>.stride
                var entries = unsafe [kinfo_proc](repeating: kinfo_proc(), count: size / stride)
                var length = unsafe entries.count * stride
                // SAFETY: the buffer is owned, `length` bytes long; sysctl writes at most that and reports how much.
                let status = entries.withUnsafeMutableBytes { buffer in
                    unsafe sysctl(&mib, UInt32(mib.count), buffer.baseAddress, &length, nil, 0)
                }
                if status == 0 {
                    return unsafe entries.prefix(length / stride)
                        .compactMap { entry in
                            let pid = unsafe entry.kp_proc.p_pid
                            guard pid > 0 else { return nil }
                            let start = unsafe entry.kp_proc.p_un.__p_starttime
                            return unsafe Process(
                                pid: pid,
                                parent: entry.kp_eproc.e_ppid,
                                group: entry.kp_eproc.e_pgid,
                                session: getsid(pid),
                                started: Int64(start.tv_sec) * 1_000_000 + Int64(start.tv_usec)
                            )
                        }
                }
                guard errno == ENOMEM else { return [] }
            }
            return []
        }

        static func platformEnvironmentBytes(of pid: Int32) -> ArraySlice<UInt8>? {
            var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
            var size = 0
            // SAFETY: a nil buffer only asks for the size; `mib` is a live local array.
            guard unsafe sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 4, size <= 4 << 20 else {
                return nil
            }
            var bytes = [UInt8](repeating: 0, count: size)
            // SAFETY: the buffer is owned and `size` bytes long; sysctl writes at most that and reports how much.
            let status = bytes.withUnsafeMutableBytes { buffer in
                unsafe sysctl(&mib, UInt32(mib.count), buffer.baseAddress, &size, nil, 0)
            }
            guard status == 0 else { return nil }
            return environmentBlock(procargs: bytes.prefix(size))
        }

        /// Mach absolute time units per nanosecond, as numerator and denominator.
        private static let timebase: (numer: UInt64, denom: UInt64) = {
            var info = mach_timebase_info_data_t()
            guard unsafe mach_timebase_info(&info) == KERN_SUCCESS, info.denom != 0 else { return (1, 1) }
            return (UInt64(info.numer), UInt64(info.denom))
        }()

        /// `ticks` Mach absolute time units in nanoseconds, exactly (a full-width product, then the division).
        static func nanoseconds(_ ticks: UInt64) -> UInt64 {
            let product = ticks.multipliedFullWidth(by: timebase.numer)
            guard product.high < timebase.denom else { return .max }
            return timebase.denom.dividingFullWidth(product).quotient
        }

        static func platformUsage(of pid: Int32) -> Usage? {
            var info = rusage_info_v4()
            // SAFETY: proc_pid_rusage writes one rusage_info_v4 into `info`, which outlives the call.
            let status = withUnsafeMutablePointer(to: &info) { pointer in
                unsafe pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    unsafe proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            guard status == 0 else { return nil }
            return Usage(
                userNanoseconds: nanoseconds(info.ri_user_time),
                systemNanoseconds: nanoseconds(info.ri_system_time),
                residentBytes: info.ri_resident_size,
                footprintBytes: info.ri_phys_footprint,
                peakFootprintBytes: info.ri_lifetime_max_phys_footprint
            )
        }
    }

#else
    extension ProcessTable {
        /// A whole small file of `/proc`, or nil.
        static func procFile(_ path: String, cap: Int = 1 << 20) -> [UInt8]? {
            let descriptor = path.withCString { unsafe open($0, O_RDONLY | O_CLOEXEC) }
            guard descriptor >= 0 else { return nil }
            defer { close(descriptor) }
            var bytes: [UInt8] = []
            var chunk = [UInt8](repeating: 0, count: 4096)
            while bytes.count < cap {
                let count = chunk.withUnsafeMutableBytes { buffer in
                    unsafe read(descriptor, buffer.baseAddress, buffer.count)
                }
                if count < 0 {
                    if errno == EINTR { continue }
                    return nil
                }
                if count == 0 { break }
                bytes.append(contentsOf: chunk[0 ..< count])
            }
            return bytes
        }

        private static let ticksPerSecond = Int64(max(1, sysconf(Int32(_SC_CLK_TCK))))
        private static let pageSize = UInt64(max(1, sysconf(Int32(_SC_PAGESIZE))))

        /// Boot time in seconds since 1970 (`btime` in `/proc/stat`).
        private static let bootTime: Int64 = {
            guard let bytes = procFile("/proc/stat") else { return 0 }
            for line in bytes.split(separator: UInt8(ascii: "\n")) where line.starts(with: Array("btime ".utf8)) {
                return Int64(String(decoding: line.dropFirst(6), as: UTF8.self)) ?? 0
            }
            return 0
        }()

        /// The fields of `/proc/<pid>/stat` after the command name, which may hold spaces and parentheses.
        static func statFields(_ bytes: [UInt8]) -> [Substring]? {
            guard let close = bytes.lastIndex(of: UInt8(ascii: ")")) else { return nil }
            let rest = String(decoding: bytes[(close + 1)...], as: UTF8.self)
            return rest.split(separator: " ", omittingEmptySubsequences: true)
        }

        static func platformList(user: UInt32) -> [Process] {
            guard let directory = unsafe opendir("/proc") else { return [] }
            defer { _ = unsafe closedir(directory) }
            var processes: [Process] = []
            while let entry = unsafe readdir(directory) {
                let name = unsafe withUnsafeBytes(of: entry.pointee.d_name) { raw in
                    unsafe String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
                }
                guard let pid = Int32(name), pid > 0 else { continue }
                var info = stat()
                guard unsafe stat("/proc/\(name)", &info) == 0, UInt32(info.st_uid) == user else { continue }
                // Fields after the name: state 0, ppid 1, pgrp 2, session 3, …, starttime 19 (clock ticks since boot).
                guard let bytes = procFile("/proc/\(name)/stat"), let fields = statFields(bytes), fields.count > 19,
                    let parent = Int32(fields[1]), let group = Int32(fields[2]), let session = Int32(fields[3]),
                    let ticks = Int64(fields[19])
                else { continue }
                let started = (bootTime * ticksPerSecond + ticks) * 1_000_000 / ticksPerSecond
                processes.append(Process(pid: pid, parent: parent, group: group, session: session, started: started))
            }
            return processes
        }

        static func platformEnvironmentBytes(of pid: Int32) -> ArraySlice<UInt8>? {
            procFile("/proc/\(pid)/environ", cap: 4 << 20).map { ArraySlice($0) }
        }

        static func platformUsage(of pid: Int32) -> Usage? {
            guard let bytes = procFile("/proc/\(pid)/stat"), let fields = statFields(bytes), fields.count > 21,
                let user = UInt64(fields[11]), let system = UInt64(fields[12]), let pages = UInt64(fields[21])
            else { return nil }
            let nanosecondsPerTick = UInt64(1_000_000_000 / ticksPerSecond)
            let resident = pages &* pageSize
            var peak = resident
            if let status = procFile("/proc/\(pid)/status") {
                for line in status.split(separator: UInt8(ascii: "\n")) where line.starts(with: Array("VmHWM:".utf8)) {
                    let digits = line.filter { $0 >= 0x30 && $0 <= 0x39 }
                    if let kilobytes = UInt64(String(decoding: digits, as: UTF8.self)) { peak = kilobytes &* 1024 }
                }
            }
            return Usage(
                userNanoseconds: user &* nanosecondsPerTick,
                systemNanoseconds: system &* nanosecondsPerTick,
                residentBytes: resident,
                footprintBytes: resident,
                peakFootprintBytes: max(peak, resident)
            )
        }
    }

#endif

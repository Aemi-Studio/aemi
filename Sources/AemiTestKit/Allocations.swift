import CAemiTestKitMalloc
import Synchronization
// `public import`: the allocation assert exposes Swift Testing's `SourceLocation` publicly.
public import Testing

#if canImport(Darwin)
    internal import Darwin
#elseif canImport(Glibc)
    internal import Glibc
#endif

/// Whether a sanitizer runtime (ASan/TSan) is loaded into this process. Two kit behaviors key off
/// it: (1) their interposed allocators bypass the default-zone `malloc_logger` the allocation
/// counter hooks, so a sanitizer run would count 0 for real allocations — counting must report
/// unavailable there; (2) their redzones/shadow frames inflate native stack frames ~3-4x, so
/// ``DepthSweep`` scales its pinned worker stack (a cap-legal recursion that fits the production
/// floor uninstrumented must not falsely SIGBUS under instrumentation).
public let sanitizerRuntimeLoaded: Bool = {
    // The sanitizer runtimes export their initializers; dlsym through the process's own global
    // scope finds them iff this run is instrumented. (The handle is bound, not passed optional:
    // Glibc declares dlsym/dlclose with a non-optional handle.)
    guard let handle = dlopen(nil, RTLD_LAZY) else { return false }
    defer { dlclose(handle) }
    return dlsym(handle, "__asan_init") != nil || dlsym(handle, "__tsan_init") != nil
}()

/// Whether allocation counting is available here. Darwin: `true` (libmalloc hook),
/// EXCEPT under a sanitizer, whose interposed allocator the hook cannot observe (see
/// ``sanitizerRuntimeLoaded``). Other platforms: `false` — the oracle then runs the body but
/// cannot measure, so `expectAllocations` becomes a no-op there (the ordo-one `.mallocCountTotal`
/// benchmark metric covers those CI legs). A test that MUST measure can gate on this.
public var allocationCountingAvailable: Bool {
    adtk_malloc_counting_available() != 0 && !sanitizerRuntimeLoaded
}

/// The calling thread's identity, as the malloc hook sees it (`pthread_self()`).
private func currentThreadID() -> UInt {
    #if canImport(Darwin)
        UInt(bitPattern: pthread_self())
    #else
        UInt(pthread_self())
    #endif
}

/// Serializes measurements. The hook is process-wide, so two measurements that overlapped (parallel tests) reset each
/// other's count, and the second `begin` saved the counting hook itself as the hook to chain to: every later allocation
/// then recursed until the stack overflowed. A window is opened and closed by separate calls, so this is a flag that
/// `acquire` waits on rather than a scope: it holds the thread that owns the measurement (0 when none).
private enum Measurements {
    private static let owner = Mutex<UInt>(0)

    /// Waits for the running measurement, if any, then takes over. A thread that already owns one traps: it would wait
    /// for itself.
    static func acquire() {
        let me = currentThreadID()
        var attempts = 0
        while true {
            let acquired = owner.withLock { current in
                precondition(current != me, "measurements must not nest")
                guard current == 0 else { return false }
                current = me
                return true
            }
            if acquired { return }
            // Measurements are short, so yield at first; a long window should not keep a core busy.
            attempts += 1
            if attempts < 64 { sched_yield() } else { usleep(500) }
        }
    }

    /// Whether the calling thread owns the measurement.
    static var heldByCurrentThread: Bool {
        let me = currentThreadID()
        return owner.withLock { $0 == me }
    }

    static func release() {
        let me = currentThreadID()
        owner.withLock { current in
            precondition(current == me, "no measurement is open on this thread")
            current = 0
        }
    }
}

/// Counts the heap allocations the calling thread makes DURING `body`. Other threads' allocations are
/// not counted, so concurrent tests cannot inflate it, and neither is work `body` hands to another
/// thread: measure a SYNCHRONOUS, single-threaded body. WARM UP first (call the body once before measuring) so one-time lazy
/// initialization doesn't skew the delta. Returns `nil` where counting is unavailable (the body still
/// runs, for its side effects). Measurements are serialized: one started while another runs waits for
/// it, so `body` must not itself measure (the nested call traps).
public func mallocDelta(_ body: () -> Void) -> Int? {
    guard allocationCountingAvailable else {
        body()
        return nil
    }
    Measurements.acquire()
    defer { Measurements.release() }
    adtk_malloc_count_begin()
    body()
    return Int(adtk_malloc_count_end())
}

/// A measurement that one thread counts and another opens and closes: a loop that runs on a thread of its own, say,
/// with a second thread that drives it and opens the window once the loop is warm. Name the counted thread with
/// ``watchCurrentThread()`` (from that thread, before the window opens), then ``begin(watching:)`` and ``end()`` from
/// one thread, which need not be the counted one. Allocations the counted thread makes between the two are the count.
/// Like ``mallocDelta(_:)`` it is serialized with every other measurement, so the window must be short and must not
/// contain a measurement of its own. Where counting is unavailable every call does nothing and ``end()`` returns `nil`.
///
/// Hand the ``Watch`` that ``watchCurrentThread()`` returns to ``begin(watching:)``. Without it ``begin(watching:)``
/// falls back to the thread named last, a single process-wide slot, so two threads that name themselves before either
/// window opens can swap: the first window then counts the second thread. The token pairs them exactly.
public enum AllocationWindow {
    /// The thread a window counts, as named by ``watchCurrentThread()``.
    public struct Watch: Sendable {
        fileprivate let thread: UInt
    }

    /// The thread last named, for a ``begin(watching:)`` that is given no ``Watch``. Consumed by the next `begin`.
    private static let lastWatched = Atomic<UInt>(0)

    /// Makes the calling thread the one whose allocations the next window counts, and returns the token that names it.
    @discardableResult
    public static func watchCurrentThread() -> Watch {
        let watch = Watch(thread: currentThreadID())
        lastWatched.store(watch.thread, ordering: .relaxed)
        return watch
    }

    /// Waits for other measurements, then starts counting `watch`'s thread: the thread named last when `watch` is
    /// `nil`, or the caller when none was named.
    public static func begin(watching watch: Watch? = nil) {
        guard allocationCountingAvailable else { return }
        Measurements.acquire()
        // Read after the serializing lock is held, and consumed, so a stale name never leaks into a later window.
        let named = lastWatched.exchange(0, ordering: .relaxed)
        let thread = watch?.thread ?? (named == 0 ? currentThreadID() : named)
        adtk_malloc_window_begin(thread)
    }

    /// Stops counting and returns the number of allocations the watched thread made since ``begin(watching:)``. Call it
    /// on the thread that called `begin`, before any teardown that allocates. Returns `nil` too when this thread has
    /// no window open.
    public static func end() -> Int? {
        guard allocationCountingAvailable, Measurements.heldByCurrentThread else { return nil }
        defer { Measurements.release() }
        return Int(adtk_malloc_count_end())
    }
}

/// The smallest allocation count observed across `repeats` measurements of the same body.
///
/// Only the measuring thread is counted, so other threads cannot inflate a sample. Repeats still
/// absorb one-off work on that thread, such as lazy initialization or allocator growth, that a
/// single warm-up did not reach; the minimum is the steady-state cost.
///
/// A regression that adds allocations raises every sample, so a minimum does not hide one.
///
/// - Parameters:
///   - repeats: How many times to measure. Must be at least 1.
///   - body: The work to measure. It must be synchronous and single-threaded.
/// - Returns: The smallest measured count, or `nil` where counting is unavailable.
public func minimumAllocations(repeats: Int = 3, _ body: () -> Void) -> Int? {
    precondition(repeats >= 1, "at least one measurement is required")
    var smallest: Int?
    for _ in 0 ..< repeats {
        guard let count = mallocDelta(body) else { return nil }
        if let current = smallest { smallest = min(current, count) } else { smallest = count }
    }
    return smallest
}

/// Asserts `body` makes at most `limit` heap allocations — a mutation-resistant performance guard for a
/// UNIT test: a re-introduced copy / box / un-reserved growth on a hot path trips it, complementing the
/// ordo-one `.mallocCountTotal` benchmark. Warm up + measure synchronously (see `mallocDelta`). Where
/// counting is unavailable it runs the body and records nothing (no false failure); returns the measured
/// count (`nil` if unavailable) for further inspection.
@discardableResult
public func expectAllocations(
    noMoreThan limit: Int,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ body: () -> Void
) -> Int? {
    guard let count = mallocDelta(body) else { return nil }
    if count > limit {
        Issue.record(
            "expected at most \(limit) allocation(s), measured \(count)", sourceLocation: sourceLocation)
    }
    return count
}

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

/// Whether process-wide allocation counting is available here. Darwin: `true` (libmalloc hook),
/// EXCEPT under a sanitizer, whose interposed allocator the hook cannot observe (see
/// ``sanitizerRuntimeLoaded``). Other platforms: `false` — the oracle then runs the body but
/// cannot measure, so `expectAllocations` becomes a no-op there (the ordo-one `.mallocCountTotal`
/// benchmark metric covers those CI legs). A test that MUST measure can gate on this.
public var allocationCountingAvailable: Bool {
    adtk_malloc_counting_available() != 0 && !sanitizerRuntimeLoaded
}

/// Serializes measurements. The counter and the hook are process-wide, so two measurements that
/// overlapped (parallel tests) reset each other's count, and the second `begin` saved the counting hook
/// itself as the hook to chain to: every later allocation then recursed until the stack overflowed.
private let measurementLock = Mutex(())

/// Counts the heap allocations made DURING `body`. Run a SYNCHRONOUS body with no concurrent work (the
/// count is process-wide) and WARM UP first (call the body once before measuring) so one-time lazy
/// initialization doesn't skew the delta. Returns `nil` where counting is unavailable (the body still
/// runs, for its side effects). Measurements are serialized: one started while another runs waits for
/// it, so `body` must not itself measure (the nested call traps).
public func mallocDelta(_ body: () -> Void) -> Int? {
    guard allocationCountingAvailable else {
        body()
        return nil
    }
    return measurementLock.withLock { _ in
        adtk_malloc_count_begin()
        body()
        return Int(adtk_malloc_count_end())
    }
}

/// The smallest allocation count observed across `repeats` measurements of the same body.
///
/// The counter observes the thread that opened the window, but a thread that starts during it can
/// still contribute, so a single measurement can be inflated by unrelated work. Taking the minimum
/// across repeats keeps the least-polluted sample, which is what a ceiling should be judged against:
/// contamination can only push a count UP, never down, so the minimum is the conservative choice for
/// a budget and a stable one for a test.
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

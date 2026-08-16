import Foundation

/// Runs `body` on a freshly spawned thread whose stack is pinned to `stackSize`
/// (512 KiB by default — the worker-stack floor the AD-family's recursive-descent
/// parsers must survive), blocks until it joins, and returns its result. Survival of
/// the join *is* the assertion: a stack overflow inside `body` kills the process with
/// SIGBUS rather than returning, so any caller that completes has proven the work
/// fits. The multi-MB main test stack would mask such an overflow — this de-dupes the
/// `onTinyStack` / `onWorkerStack` runners that exposed the SQL-parser SIGBUS.
///
/// `body` must be total (catch its own errors); only an unrecoverable overflow should
/// fail to return. No recursion here — the depth lives entirely in `body`.
public func runOnConstrainedStack<R: Sendable>(
    stackSize: Int = 512 * 1024,
    name: String = "AemiTestKit.constrained-stack",
    _ body: @escaping @Sendable () -> R
) -> R {
    let box = ResultBox<R>()
    let done = DispatchSemaphore(value: 0)
    let worker = Thread {
        box.set(body())
        done.signal()
    }
    worker.stackSize = stackSize
    worker.name = name
    worker.start()
    done.wait()
    return box.take()
}

/// The Void specialization (the former `onWorkerStack`): run `body` on the pinned
/// stack and block until it returns.
public func runOnConstrainedStack(
    stackSize: Int = 512 * 1024,
    name: String = "AemiTestKit.constrained-stack",
    _ body: @escaping @Sendable () -> Void
) {
    let _: Int = runOnConstrainedStack(stackSize: stackSize, name: name) {
        body()
        return 0
    }
}

/// A minimal `Sendable` hand-off so the constrained-stack worker can ferry its result
/// back without `nonisolated(unsafe)`.
private final class ResultBox<R: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: R?
    func set(_ v: R) {
        lock.lock()
        value = v
        lock.unlock()
    }
    func take() -> R {
        lock.lock()
        defer { lock.unlock() }
        guard let value else { preconditionFailure("constrained-stack worker produced no result") }
        return value
    }
}

/// A canonical depth sweep for recursion-cap regression locks: shallow values, each
/// cap straddled at `cap-1 / cap / cap+1`, and a far-past-cap depth — run on a
/// constrained stack so a missing or mis-sized cap surfaces as a SIGBUS rather than
/// passing silently. Built iteratively (no recursion in the kit).
public struct DepthSweep: Sendable {
    public let depths: [Int]

    public init(depths: [Int]) { self.depths = depths }

    /// A sweep straddling each cap in `caps`, from shallow up to `maxDepth`. The
    /// result is sorted and de-duplicated, so passing the same cap twice is harmless.
    public static func around(_ caps: [Int], upTo maxDepth: Int = 3000) -> DepthSweep {
        var set = Set<Int>([1, 8, 16, 32])
        for cap in caps where cap > 0 {
            set.insert(cap - 1)
            set.insert(cap)
            set.insert(cap + 1)
        }
        set.insert(maxDepth / 3)
        set.insert(maxDepth)
        let depths = set.filter { $0 >= 1 && $0 <= maxDepth }.sorted()
        return DepthSweep(depths: depths)
    }

    public static func around(_ caps: Int..., upTo maxDepth: Int = 3000) -> DepthSweep {
        around(caps, upTo: maxDepth)
    }

    /// The default sweep stack: the family's 512 KiB worker floor, scaled to 4 MiB when a
    /// sanitizer runtime is loaded — ASan redzones / TSan shadow frames inflate native frames
    /// ~3-4x, so a CAP-LEGAL recursion that fits the production floor uninstrumented would
    /// falsely SIGBUS under instrumentation (observed: a ~250-frame binder walk at ~1.2 KiB/frame
    /// clean vs ~3.3 KiB under ASan). The caps' correctness — reject past-cap, accept under-cap —
    /// is stack-size-independent; the 512 KiB margin proof is only meaningful uninstrumented.
    /// (`runOnConstrainedStack` itself keeps exact sizes: deliberate-overflow tests need them.)
    public static var defaultStackSize: Int {
        sanitizerRuntimeLoaded ? 4 * 1024 * 1024 : 512 * 1024
    }

    /// Runs `body(depth)` on a constrained stack at each swept depth. `body` is
    /// expected to be total — it should evaluate the depth-`n` shape and record any
    /// unexpected outcome itself; reaching the end of the sweep proves none overflowed.
    public func run(
        stackSize: Int = DepthSweep.defaultStackSize,
        name: String = "AemiTestKit.depth-sweep",
        _ body: @escaping @Sendable (Int) -> Void
    ) {
        for depth in depths {
            runOnConstrainedStack(stackSize: stackSize, name: name) { body(depth) }
        }
    }
}

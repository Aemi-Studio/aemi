import Synchronization

/// The async sibling of `ThreadGate`: a one-permit gate that **suspends a Task**
/// instead of blocking an OS thread. A holder `await`s `waitUntilOpen()` and the
/// cooperative thread is released back to the pool (no blocked thread, no priority
/// inversion); `open()` resumes the longest-waiting holder, or banks a permit if none is
/// waiting. This is the `Task`-based counterpart for code that already lives on
/// async/await — `ThreadGate` remains the right tool for the pthread / dispatch-queue
/// engine paths that must occupy a *real* thread.
///
/// Built on the shared `ContinuationRegistry` (a `Synchronization.Mutex` plus a
/// continuation table) — fully `Sendable`, no `Dispatch`. Continuations resume *outside*
/// the lock, and a cancelled `waitUntilOpen()` throws `CancellationError` and unregisters.
public final class AsyncGate: Sendable {
    private struct State {
        /// Banked permits from `open()` calls that arrived with no waiter parked.
        var permits: Int
        /// Suspended holders, all parked at key 0 so `wakeOne()` releases them FIFO (by id).
        var waiters = ContinuationRegistry<Int, Void>()
    }

    private let state: Mutex<State>

    /// A closed gate (the usual case): holders suspend until `open()`. `initiallyOpen`
    /// banks one permit, so the first `waitUntilOpen()` returns without suspending.
    public init(initiallyOpen: Bool = false) {
        state = Mutex(State(permits: initiallyOpen ? 1 : 0))
    }

    /// Tasks currently suspended on the gate — the async analogue of
    /// `TestClock.sleeperCount`, so a test can wait for a holder to park before opening.
    public var waiterCount: Int { state.withLock { $0.waiters.count } }

    /// Suspend until the gate is opened, or consume a banked permit and proceed at once.
    /// Honors cancellation: a cancelled wait throws `CancellationError` and unregisters.
    public func waitUntilOpen() async throws {
        try Task.checkCancellation()
        let id = state.withLock { $0.waiters.makeID() }
        enum Action { case proceed, cancelled, suspended }
        try await withTaskCancellationHandler {
            try await withUnsafeThrowingContinuation {
                (continuation: UnsafeContinuation<Void, any Error>) in
                let action = state.withLock { s -> Action in
                    if Task.isCancelled { return .cancelled }
                    if s.permits > 0 {
                        s.permits -= 1
                        return .proceed
                    }
                    s.waiters.park(id: id, key: 0, continuation)
                    return .suspended
                }
                switch action {
                    case .proceed: continuation.resume()
                    case .cancelled: continuation.resume(throwing: CancellationError())
                    case .suspended: break
                }
            }
        } onCancel: {
            state.withLock { $0.waiters.remove(id: id) }?.resume(throwing: CancellationError())
        }
    }

    /// Open the gate for one holder: resume the longest-waiting suspended Task, or bank a
    /// permit if none is waiting. The continuation resumes outside the lock.
    public func open() {
        let woken = state.withLock { s -> UnsafeContinuation<Void, any Error>? in
            if let continuation = s.waiters.wakeOne() { return continuation }
            s.permits += 1
            return nil
        }
        woken?.resume()
    }
}

/// The async analogue of `withThreadGatedBatch`: spawn `hold` (which `await`s the gate inside
/// the serial work it occupies), run `body` to enqueue the work that should pile up
/// behind the holder, then open the gate and await the holder. Deterministic — the batch
/// is assembled before the gate opens, with no blocked threads or timing assumptions.
public func withAsyncGatedBatch(
    hold: @escaping @Sendable (_ gate: AsyncGate) async -> Void,
    _ body: (_ openGate: @Sendable () -> Void) async throws -> Void
) async rethrows {
    let gate = AsyncGate()
    let holder = Task { await hold(gate) }
    try await body { gate.open() }
    await holder.value
}

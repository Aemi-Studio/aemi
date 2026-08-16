import Synchronization

/// A one-way broadcast latch: `open()` releases **every** waiter at once and stays open, so any
/// later `wait()` returns without suspending.
///
/// This is the counterpart to ``AsyncGate``, and the distinction matters — the two are easy to
/// confuse and behave differently under the same call sequence:
///
/// | | ``AsyncGate`` | ``AsyncLatch`` |
/// |---|---|---|
/// | `open()` with 3 waiters | releases **one** | releases **all three** |
/// | `open()` with no waiter | banks a permit | latches open forever |
/// | second `open()` | banks another permit | no-op (idempotent) |
///
/// Reach for the latch when the production signal is fire-and-forget and every observer should
/// proceed — "the server is ready", "the fixture finished loading". Reach for the gate when each
/// `open()` must hand a permit to exactly one holder.
///
/// Built on the shared ``ContinuationRegistry`` like the rest of the kit: `Sendable`, no `Dispatch`,
/// continuations resumed **outside** the lock, and a cancelled `wait()` throws `CancellationError`
/// and unregisters rather than leaking a parked continuation.
public final class AsyncLatch: Sendable {
    private struct State {
        /// Once true the latch never closes again; `wait()` stops suspending.
        var isOpen: Bool
        /// Waiters all park at key 0, so `wake(upTo: 0)` drains them in FIFO (id) order.
        var waiters = ContinuationRegistry<Int, Void>()
    }

    private let state: Mutex<State>

    /// A closed latch (the usual case). `initiallyOpen` starts it latched, so the first `wait()`
    /// returns without suspending.
    public init(initiallyOpen: Bool = false) {
        state = Mutex(State(isOpen: initiallyOpen))
    }

    /// Whether `open()` has been called (or the latch was created open).
    public var isOpen: Bool { state.withLock(\.isOpen) }

    /// Tasks currently suspended on the latch — lets a test rendezvous with the waiters before
    /// opening, exactly as ``AsyncGate/waiterCount`` does.
    public var waiterCount: Int { state.withLock { $0.waiters.count } }

    /// Suspend until the latch opens; return immediately if it already has.
    ///
    /// Honors cancellation: a cancelled wait unregisters and throws `CancellationError` at the call
    /// site rather than surfacing later in an unrelated `Task.checkCancellation()`.
    public func wait() async throws {
        try Task.checkCancellation()
        let id = state.withLock { $0.waiters.makeID() }
        enum Action { case proceed, cancelled, suspended }
        try await withTaskCancellationHandler {
            try await withUnsafeThrowingContinuation {
                (continuation: UnsafeContinuation<Void, any Error>) in
                let action = state.withLock { s -> Action in
                    if Task.isCancelled { return .cancelled }
                    if s.isOpen { return .proceed }
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

    /// Latch open and resume every waiter, in FIFO order. Idempotent — a second call is a no-op
    /// rather than a trap, so production code can fire the signal without coordinating who resumes
    /// whom. Continuations resume outside the lock.
    public func open() {
        let woken = state.withLock { s -> [(UnsafeContinuation<Void, any Error>, Void)] in
            guard !s.isOpen else { return [] }
            s.isOpen = true
            return s.waiters.wake(upTo: 0, with: ())
        }
        for (continuation, _) in woken {
            continuation.resume()
        }
    }
}

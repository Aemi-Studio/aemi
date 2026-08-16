import Foundation
import Synchronization

/// Counting semaphore backed by checked continuations.
///
/// `wait()` decrements the permit counter; if no permit is available,
/// it suspends until a `signal()` resumes it. `signal()` increments
/// the counter or hands a permit directly to the longest-waiting
/// awaiter (FIFO). Initialising with `value > 0` pre-loads permits.
///
/// Use when the production signal fires multiple times and the test
/// wants to await each occurrence individually.
///
/// ## Cancellation
///
/// `wait()` is cancellation-aware. A cancelled waiter is removed
/// from the FIFO queue and its continuation resumed with
/// `CancellationError` (no permit is consumed, so the count is
/// preserved). The next `signal()` resumes the next-in-line.
///
/// ## Example
///
/// ```swift
/// let sem = AsyncSemaphore()
/// undoController.onDidCommit = { _ in sem.signal() }
/// presenter.updateExposure(1.0)
/// presenter.updateContrast(0.5)
/// try await sem.wait()  // first commit
/// try await sem.wait()  // second commit
/// ```
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
public final class AsyncSemaphore: Sendable {

    private let state: Mutex<State>

    private struct State {
        var value: Int
        var waiters: [Waiter] = []
        var nextWaiterID: UInt64 = 0
    }

    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<Void, any Error>
    }

    public init(value: Int = 0) {
        precondition(value >= 0, "AsyncSemaphore initial value must be non-negative")
        self.state = Mutex(State(value: value))
    }

    /// Releases a permit. If a waiter is queued, resumes it directly
    /// (the permit never enters the counter — strict FIFO handoff).
    public func signal() {
        let resumer: CheckedContinuation<Void, any Error>? = state.withLock { current in
            if current.waiters.isEmpty {
                current.value += 1
                return nil
            }
            return current.waiters.removeFirst().continuation
        }
        resumer?.resume()
    }

    /// Acquires a permit. Suspends if no permits are available.
    /// Throws `CancellationError` if the awaiting task is cancelled.
    public func wait() async throws {
        try Task.checkCancellation()

        let waiterID: UInt64 = state.withLock { current in
            current.nextWaiterID += 1
            return current.nextWaiterID
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
                let outcome: Outcome = state.withLock { current in
                    if Task.isCancelled { return .cancelled }
                    if current.value > 0 {
                        current.value -= 1
                        return .acquired
                    }
                    current.waiters.append(Waiter(id: waiterID, continuation: cont))
                    return .queued
                }
                switch outcome {
                    case .acquired: cont.resume()
                    case .cancelled: cont.resume(throwing: CancellationError())
                    case .queued: break  // waits in queue
                }
            }
        } onCancel: {
            let resumer: CheckedContinuation<Void, any Error>? = state.withLock { current in
                guard let idx = current.waiters.firstIndex(where: { $0.id == waiterID })
                else { return nil }
                let cont = current.waiters[idx].continuation
                current.waiters.remove(at: idx)
                return cont
            }
            resumer?.resume(throwing: CancellationError())
        }
    }

    private enum Outcome { case acquired, queued, cancelled }
}

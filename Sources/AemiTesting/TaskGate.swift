import Foundation
import Synchronization

/// Single-shot continuation barrier.
///
/// `wait()` suspends until `open()` is called. Once open, subsequent
/// `wait()` calls return immediately. `open()` is idempotent —
/// calling it twice is a no-op (not a trap), so production code can
/// safely fire the signal without coordinating who-resumes-whom.
///
/// Use when the production signal is fire-and-forget and the test
/// wants to assert on state immediately after the first fire.
///
/// ## Cancellation
///
/// `wait()` is cancellation-aware via `withTaskCancellationHandler`.
/// A cancelled waiter is removed from the queue and its continuation
/// resumed with `CancellationError`, so the awaiting `try await
/// gate.wait()` throws at the call site (not in some unrelated
/// downstream `Task.checkCancellation()`).
///
/// ## Example
///
/// ```swift
/// let gate = TaskGate()
/// controller.scheduleCommit(delayMilliseconds: 50) { gate.open() }
/// try await gate.wait()
/// #expect(controller.canUndo)
/// ```
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
public final class TaskGate: Sendable {

    private let state: Mutex<State>

    private struct State {
        var isOpen: Bool = false
        var waiters: [Waiter] = []
        var nextWaiterID: UInt64 = 0
    }

    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<Void, any Error>
    }

    public init() {
        self.state = Mutex(State())
    }

    /// Opens the gate, resuming every waiter atomically. Idempotent.
    public func open() {
        let waiters: [Waiter] = state.withLock { current in
            guard !current.isOpen else { return [] }
            current.isOpen = true
            let drained = current.waiters
            current.waiters.removeAll()
            return drained
        }
        for waiter in waiters {
            waiter.continuation.resume()
        }
    }

    /// Suspends until `open()` is called. Returns immediately if the
    /// gate is already open. Throws `CancellationError` if the
    /// awaiting task is cancelled before the gate opens.
    public func wait() async throws {
        try Task.checkCancellation()

        let waiterID: UInt64 = state.withLock { current in
            current.nextWaiterID += 1
            return current.nextWaiterID
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
                let releaseImmediately: Bool = state.withLock { current in
                    if Task.isCancelled {
                        return true  // throw below via Task.checkCancellation
                    }
                    if current.isOpen { return true }
                    current.waiters.append(Waiter(id: waiterID, continuation: cont))
                    return false
                }
                if releaseImmediately {
                    if Task.isCancelled {
                        cont.resume(throwing: CancellationError())
                    } else {
                        cont.resume()
                    }
                }
            }
        } onCancel: {
            // Remove our waiter (if still queued) and throw
            // CancellationError through its continuation. The resume
            // race against `open()` is safe — both paths first check
            // for the waiter under the lock; only one finds it.
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
}

import Foundation
import Synchronization

/// Virtual `Clock` whose `sleep(for:)` only resumes when the test
/// calls ``advance(by:)``.
///
/// Inject into any production type whose `init` accepts
/// `clock: any Clock<Duration> = ContinuousClock()` so a
/// `Task.sleep(for:)`-style debounce becomes deterministic in tests:
/// instead of waiting `N` real milliseconds, the test rendezvouses
/// with the production-side `sleep` call via
/// ``waitForSleepers(count:)``, then calls ``advance(by:)`` to
/// release every sleeper whose deadline has elapsed.
///
/// ## Why an explicit rendezvous (no `Task.yield()`)
///
/// `sleep(for:)` computes its deadline as `clock.now + duration` at
/// the moment sleep is called. If the test calls `advance(by:)`
/// before the spawned Task has reached `sleep`, the clock moves but
/// no sleeper is queued — and when the Task finally calls `sleep`,
/// the new deadline lives in the future relative to the already-
/// advanced clock, so the sleeper waits forever.
///
/// `Task.yield()` before `advance` "fixes" this in practice but is
/// non-deterministic under load. ``waitForSleepers(count:)``
/// suspends on a `CheckedContinuation` resumed *only* when the
/// requested number of additional sleepers have been appended to
/// the queue — pure event-driven rendezvous through Swift
/// Concurrency, no yielding, no polling, no timeouts.
///
/// ## "N more" semantics
///
/// `waitForSleepers(count:)` waits for `count` ADDITIONAL sleepers
/// past whatever was queued at registration time. This matches the
/// human intent of every realistic call site: "wait for my new
/// spawned Task to register its sleeper", not "wait until the queue
/// has at least N entries total". The distinction only matters when
/// the test composes multiple awaits mid-flow — a queue-size
/// threshold would trip immediately if a previous gated sleeper is
/// still queued.
///
/// ## Cancellation
///
/// Both `sleep(until:tolerance:)` and `waitForSleepers(count:)` are
/// cancellation-aware via `withTaskCancellationHandler`. Cancelled
/// waiters / sleepers are removed from their queues and their
/// continuations resumed with `CancellationError`, surfacing the
/// cancellation at the actual call site (not via downstream
/// `Task.checkCancellation()` indirection).
///
/// ## Typical pattern
///
/// ```swift
/// let clock = TestClock()
/// let controller = UndoController(clock: clock)
/// let gate = TaskGate()
///
/// controller.scheduleCommit(delayMilliseconds: 50) { gate.open() }
/// try await clock.waitForSleepers()                // production reached sleep
/// await clock.advance(by: .milliseconds(50))       // drain sleeper
/// try await gate.wait()                            // production-opened signal
/// ```
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
public final class TestClock: Clock, Sendable {

    public typealias Duration = Swift.Duration

    public struct Instant: InstantProtocol, Sendable {

        public let offset: Duration

        public init(offset: Duration) {
            self.offset = offset
        }

        public func advanced(by duration: Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        public func duration(to other: Instant) -> Duration {
            other.offset - offset
        }

        public static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }
    }

    private let state: Mutex<State>

    private struct State {
        var now: Instant = Instant(offset: .zero)
        var sleepers: [Sleeper] = []
        var registrationWaiters: [RegistrationWaiter] = []
        var nextSleeperID: UInt64 = 0
        var nextWaiterID: UInt64 = 0
    }

    private struct Sleeper {
        let id: UInt64
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct RegistrationWaiter {
        let id: UInt64
        var remaining: Int  // "N more" decrement counter
        let continuation: CheckedContinuation<Void, any Error>
    }

    public init() {
        self.state = Mutex(State())
    }

    public var now: Instant { state.withLock { $0.now } }
    public var minimumResolution: Duration { .zero }

    // MARK: - Clock conformance

    public func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try Task.checkCancellation()

        let sleeperID: UInt64 = state.withLock { current in
            current.nextSleeperID += 1
            return current.nextSleeperID
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
                // Append the sleeper AND decrement matching
                // registration waiters atomically under the lock.
                // Resume them outside the lock to avoid re-entrancy
                // into the clock from the resumed task.
                let (outcome, registrationsToResume):
                    (SleepOutcome, [CheckedContinuation<Void, any Error>])
                    = state.withLock { current in
                        if Task.isCancelled { return (.cancelled, []) }
                        if current.now >= deadline { return (.deadlineAlreadyPast, []) }
                        current.sleepers.append(
                            Sleeper(id: sleeperID, deadline: deadline, continuation: cont))

                        // Decrement every registration waiter by 1
                        // ("one more sleeper just registered").
                        // Resume any whose remaining reaches zero.
                        var resumed: [CheckedContinuation<Void, any Error>] = []
                        var stillWaiting: [RegistrationWaiter] = []
                        for var waiter in current.registrationWaiters {
                            waiter.remaining -= 1
                            if waiter.remaining <= 0 {
                                resumed.append(waiter.continuation)
                            } else {
                                stillWaiting.append(waiter)
                            }
                        }
                        current.registrationWaiters = stillWaiting
                        return (.suspended, resumed)
                    }
                switch outcome {
                    case .cancelled: cont.resume(throwing: CancellationError())
                    case .deadlineAlreadyPast: cont.resume()
                    case .suspended: break
                }
                for waiter in registrationsToResume {
                    waiter.resume()
                }
            }
        } onCancel: {
            let resumer: CheckedContinuation<Void, any Error>? = state.withLock { current in
                guard let idx = current.sleepers.firstIndex(where: { $0.id == sleeperID })
                else { return nil }
                let cont = current.sleepers[idx].continuation
                current.sleepers.remove(at: idx)
                return cont
            }
            resumer?.resume(throwing: CancellationError())
        }
    }

    // MARK: - Test API

    /// Suspends until `count` ADDITIONAL sleepers register past
    /// the current queue state. See the type-level "N more
    /// semantics" doc for rationale.
    ///
    /// Throws `CancellationError` if the awaiting task is cancelled
    /// before the count is satisfied.
    public func waitForSleepers(count: Int = 1) async throws {
        precondition(count >= 1, "waitForSleepers count must be >= 1")
        try Task.checkCancellation()

        let waiterID: UInt64 = state.withLock { current in
            current.nextWaiterID += 1
            return current.nextWaiterID
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
                let outcome: WaitOutcome = state.withLock { current in
                    if Task.isCancelled { return .cancelled }
                    // "N more" — never short-circuit on existing
                    // queue size. Always wait for `count` additional
                    // registrations from this point forward.
                    current.registrationWaiters.append(
                        RegistrationWaiter(
                            id: waiterID, remaining: count, continuation: cont))
                    return .queued
                }
                switch outcome {
                    case .cancelled: cont.resume(throwing: CancellationError())
                    case .queued: break
                }
            }
        } onCancel: {
            let resumer: CheckedContinuation<Void, any Error>? = state.withLock { current in
                guard let idx = current.registrationWaiters.firstIndex(where: { $0.id == waiterID })
                else { return nil }
                let cont = current.registrationWaiters[idx].continuation
                current.registrationWaiters.remove(at: idx)
                return cont
            }
            resumer?.resume(throwing: CancellationError())
        }
    }

    /// Moves the virtual clock forward by `duration`, resuming every
    /// sleeper whose deadline has elapsed in FIFO (insertion) order.
    ///
    /// Synchronous w.r.t. state mutation: the queue is drained and
    /// every due continuation has had `.resume()` called before
    /// `advance` returns. Whether each resumed continuation's body
    /// has actually *run* by then depends on the scheduler and the
    /// awaiting actor's queue — which is exactly why the test
    /// should `await` an observable signal from the resumed work
    /// (typically `TaskGate.wait()` on a gate the production code
    /// opens in its post-sleep body), not insert a `Task.yield()`
    /// here.
    public func advance(by duration: Duration) {
        let toRelease: [CheckedContinuation<Void, any Error>] = state.withLock { current in
            current.now = current.now.advanced(by: duration)
            var due: [Sleeper] = []
            var remaining: [Sleeper] = []
            for sleeper in current.sleepers {
                if current.now >= sleeper.deadline {
                    due.append(sleeper)
                } else {
                    remaining.append(sleeper)
                }
            }
            current.sleepers = remaining
            due.sort { $0.id < $1.id }
            return due.map(\.continuation)
        }
        for cont in toRelease {
            cont.resume()
        }
    }

    private enum SleepOutcome { case deadlineAlreadyPast, suspended, cancelled }
    private enum WaitOutcome { case queued, cancelled }
}

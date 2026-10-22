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
/// suspends until the requested number of sleepers is queued. Sleepers that registered
/// before the wait count toward the threshold, so scheduling order cannot lose a wakeup.
///
/// ## Queue threshold
///
/// `waitForSleepers(count:)` observes the current queue size. When composing multiple
/// waits, include sleepers that are still queued in the requested count. For example,
/// after waiting for one sleeper, use `count: 3` to await two more while the first remains.
///
/// ## Further registrations
///
/// ``waitForAdditionalSleepers(_:)`` counts registrations after the call instead of the queue
/// size, for staging a second wave while the first is still queued. When the wait cannot be
/// parked before the sleeper registers, take a ``registrationMark()`` synchronously first and
/// use ``waitForSleepers(_:after:)``.
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
public final class TestClock: Clock, Sendable, CustomStringConvertible {
    public typealias Duration = Swift.Duration

    public struct Instant: InstantProtocol, Sendable {
        public let offset: Duration

        public init(offset: Duration = .zero) {
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

    /// A point in the clock's registration history, taken synchronously with ``registrationMark()`` so a later
    /// ``waitForSleepers(_:after:)`` counts exactly the sleepers that registered after it, whatever task ran
    /// first.
    public struct RegistrationMark: Sendable, Hashable {
        fileprivate let registrations: UInt64
    }

    private typealias Continuation = CheckedContinuation<Void, any Error>

    private struct Sleeper {
        let id: UInt64
        let deadline: Instant
        /// Whether the sleep counts toward ``sleeperCount`` and the rendezvous (see ``withUntrackedSleeps(_:)``).
        let counted: Bool
        let continuation: Continuation
    }

    /// What a rendezvous waits for.
    private enum Condition {
        case trackedSleepers(atLeast: Int)
        case untrackedSleepers(atLeast: Int)
        case registrations(reaching: UInt64)
    }

    private struct Waiter {
        let id: UInt64
        let condition: Condition
        let continuation: Continuation
    }

    private struct State {
        var now = Instant(offset: .zero)
        var sleepers: [Sleeper] = []
        var waiters: [Waiter] = []
        /// Counted sleepers registered since the clock was created, cancelled ones included; the baseline every
        /// ``RegistrationMark`` is taken against.
        var registrations: UInt64 = 0
        var nextID: UInt64 = 0

        mutating func makeID() -> UInt64 {
            nextID += 1
            return nextID
        }

        var trackedCount: Int { sleepers.reduce(0) { $0 + ($1.counted ? 1 : 0) } }

        func isSatisfied(_ condition: Condition) -> Bool {
            switch condition {
                case .trackedSleepers(let count): trackedCount >= count
                case .untrackedSleepers(let count): sleepers.count - trackedCount >= count
                case .registrations(let target): registrations >= target
            }
        }

        /// Removes and returns, in the order they began waiting, every waiter the current state satisfies.
        /// Callers resume the result *outside* the lock.
        mutating func takeSatisfiedWaiters() -> [Continuation] {
            let (ready, waiting) = waiters.reduce(into: ([Waiter](), [Waiter]())) { split, waiter in
                if isSatisfied(waiter.condition) { split.0.append(waiter) } else { split.1.append(waiter) }
            }
            waiters = waiting
            return ready.map(\.continuation)
        }
    }

    private let state = Mutex(State())

    public init() {}

    public var now: Instant { state.withLock { $0.now } }
    public var minimumResolution: Duration { .zero }

    /// How many tasks are currently parked in ``sleep(until:tolerance:)``. Lets a test sequence deterministically
    /// instead of guessing with a `Task.yield()`.
    ///
    /// Sleeps the harness starts for itself — a probe's or a spy's timeout — are *untracked* and left out (see
    /// ``withUntrackedSleeps(_:)``), so only the code under test and the test's own sleepers count.
    public var sleeperCount: Int { state.withLock { $0.trackedCount } }

    /// How many untracked sleeps are currently parked: the timeouts of probe and spy waits that were given this
    /// clock. A test that drives such a timeout rendezvouses with it here, then advances.
    public var untrackedSleeperCount: Int { state.withLock { $0.sleepers.count - $0.trackedCount } }

    /// The clock's time and what is parked on it, for a failure message.
    public var description: String {
        let (now, sleepers, waiters) = state.withLock { ($0.now, $0.sleepers, $0.waiters.count) }
        let deadlines = sleepers.map { "\($0.deadline.offset)\($0.counted ? "" : " (untracked)")" }
        return "TestClock(now: \(now.offset), sleepers: [\(deadlines.joined(separator: ", "))], "
            + "rendezvous waiters: \(waiters))"
    }

    // MARK: - Clock conformance

    public func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try Task.checkCancellation()

        let sleeperID = state.withLock { $0.makeID() }
        let counted = !HarnessSleep.isActive

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: Continuation) in
                // Append the sleeper and satisfy rendezvous thresholds atomically under the lock. Resume them
                // outside the lock to avoid re-entrancy into the clock from the resumed task.
                let (outcome, rendezvous) = state.withLock { current -> (SleepOutcome, [Continuation]) in
                    if Task.isCancelled { return (.cancelled, []) }
                    if current.now >= deadline { return (.deadlineAlreadyPast, []) }
                    current.sleepers.append(
                        Sleeper(id: sleeperID, deadline: deadline, counted: counted, continuation: cont))
                    if counted { current.registrations &+= 1 }
                    return (.suspended, current.takeSatisfiedWaiters())
                }
                switch outcome {
                    case .cancelled: cont.resume(throwing: CancellationError())
                    case .deadlineAlreadyPast: cont.resume()
                    case .suspended: break
                }
                for waiter in rendezvous {
                    waiter.resume()
                }
            }
        } onCancel: {
            let resumer: Continuation? = state.withLock { current in
                guard let idx = current.sleepers.firstIndex(where: { $0.id == sleeperID })
                else { return nil }
                return current.sleepers.remove(at: idx).continuation
            }
            resumer?.resume(throwing: CancellationError())
        }
    }

    // MARK: - Test API

    /// Suspends until at least `count` sleepers are queued, including existing sleepers.
    /// - Parameter count: The minimum queue size, including sleepers from earlier waits.
    /// - Throws: `CancellationError` if cancelled before the threshold is satisfied.
    /// - Precondition: `count` must be positive.
    public func waitForSleepers(count: Int = 1) async throws {
        precondition(count >= 1, "waitForSleepers count must be >= 1")
        try await rendezvous(.trackedSleepers(atLeast: count))
    }

    /// Suspends until at least `count` sleepers are queued, including existing sleepers: the same as
    /// ``waitForSleepers(count:)``, in the spelling the `AemiTestKit` clock uses.
    public func waitForSleepers(atLeast count: Int) async throws {
        try await waitForSleepers(count: count)
    }

    /// Suspends until at least `count` untracked sleeps are parked: the timeout of a probe or spy wait given this
    /// clock. Use it to know a timeout is armed before advancing past it.
    /// - Throws: `CancellationError` if cancelled before the threshold is satisfied.
    public func waitForUntrackedSleepers(atLeast count: Int) async throws {
        try await rendezvous(.untrackedSleepers(atLeast: count))
    }

    /// The current point in the registration history, for ``waitForSleepers(_:after:)``.
    ///
    /// Synchronous, so a test takes it before spawning the work whose sleeper it wants to wait
    /// for; the wait itself may then start on any task, in any order, without losing the sleeper.
    public func registrationMark() -> RegistrationMark {
        RegistrationMark(registrations: state.withLock { $0.registrations })
    }

    /// Suspends until `count` sleepers have registered after `mark`, counting a sleeper that was
    /// cancelled or released in the meantime.
    ///
    /// Unlike ``waitForSleepers(count:)``, which observes the queue size, this counts
    /// registrations, so it stages a second wave of sleepers while the first is still queued and
    /// is never satisfied by a sleeper that registered before the mark.
    ///
    /// - Parameters:
    ///   - count: The number of further registrations to wait for; a non-positive count returns
    ///     immediately.
    ///   - mark: The baseline, from ``registrationMark()``.
    /// - Throws: `CancellationError` if cancelled before the registrations happened.
    public func waitForSleepers(_ count: Int, after mark: RegistrationMark) async throws {
        try Task.checkCancellation()
        guard count > 0 else { return }
        try await rendezvous(.registrations(reaching: mark.registrations &+ UInt64(count)))
    }

    /// Suspends until `count` further sleepers register, counting only registrations after this
    /// call starts; the same as ``waitForSleepers(_:after:)`` with a mark taken now.
    ///
    /// "Now" is when this call *runs*, not when the task that makes it was created: a wait spawned alongside the
    /// work can start after the sleeper it wants has already registered, and then waits for one more that never
    /// comes. Take a ``registrationMark()`` synchronously before spawning the work and use
    /// ``waitForSleepers(_:after:)`` in that case.
    ///
    /// - Parameter count: The number of further registrations; a non-positive count returns
    ///   immediately.
    /// - Throws: `CancellationError` if cancelled before the registrations happened.
    public func waitForAdditionalSleepers(_ count: Int) async throws {
        try await waitForSleepers(count, after: registrationMark())
    }

    /// The shared choreography of every rendezvous wait: reserve an id, then — atomically with the cancellation
    /// check — either find the condition already met or queue the continuation, and make cancellation dequeue it
    /// and throw.
    private func rendezvous(_ condition: Condition) async throws {
        try Task.checkCancellation()
        let waiterID = state.withLock { $0.makeID() }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: Continuation) in
                let outcome: WaitOutcome = state.withLock { current in
                    if Task.isCancelled { return .cancelled }
                    if current.isSatisfied(condition) { return .satisfied }
                    current.waiters.append(Waiter(id: waiterID, condition: condition, continuation: cont))
                    return .queued
                }
                switch outcome {
                    case .cancelled: cont.resume(throwing: CancellationError())
                    case .satisfied: cont.resume()
                    case .queued: break
                }
            }
        } onCancel: {
            let resumer: Continuation? = state.withLock { current in
                guard let idx = current.waiters.firstIndex(where: { $0.id == waiterID })
                else { return nil }
                return current.waiters.remove(at: idx).continuation
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
        release { $0.now = $0.now.advanced(by: duration) }
    }

    /// Moves the virtual clock to `instant` (no-op if it is already at or past it), resuming every sleeper whose
    /// deadline has elapsed.
    ///
    /// The comparison and the move happen under one lock acquisition, so concurrent calls land on the latest
    /// instant instead of each adding its own distance.
    public func advance(to instant: Instant) {
        release { if instant > $0.now { $0.now = instant } }
    }

    /// Wakes every parked sleeper by advancing to the furthest pending deadline — the "let all remaining timers
    /// fire" step at the end of a deterministic time test. Untracked sleeps (a probe's timeout) are ignored.
    public func runToLastSleeper() {
        let furthest = state.withLock { $0.sleepers.lazy.filter(\.counted).map(\.deadline).max() }
        if let furthest { advance(to: furthest) }
    }

    /// Releases everything that is parked — sleepers (tracked or not) and rendezvous waiters — by making each throw
    /// `CancellationError`, and returns how many were released. Time does not move.
    ///
    /// Call it at the end of a test whose code under test leaves a sleeper parked on purpose, so the parked task
    /// finishes instead of outliving the test. Unlike ``runToLastSleeper()``, which makes the sleeps *succeed*, this
    /// makes them fail, so the code under test sees a cancellation rather than the time it was waiting for.
    @discardableResult
    public func drain() -> Int {
        let released = state.withLock { current in
            let continuations = current.sleepers.map(\.continuation) + current.waiters.map(\.continuation)
            current.sleepers.removeAll()
            current.waiters.removeAll()
            return continuations
        }
        for continuation in released { continuation.resume(throwing: CancellationError()) }
        return released.count
    }

    /// Runs `body` with every `TestClock` sleep that the tasks it *creates* start marked *untracked*.
    ///
    /// An untracked sleep parks and wakes like any other, but is not counted by ``sleeperCount``, does not satisfy
    /// ``waitForSleepers(count:)`` or a registration mark, and is ignored by ``runToLastSleeper()``. Probe and spy
    /// waits use it for their timeouts: the harness's own timer must not make a rendezvous believe the code under
    /// test has reached its `sleep`.
    ///
    /// The marking is a task-local, so it follows the tasks created inside `body` (`Task { }`, `group.addTask`) and
    /// nothing else.
    public static func withUntrackedSleeps<Result>(_ body: () throws -> Result) rethrows -> Result {
        try HarnessSleep.$isActive.withValue(true, operation: body)
    }

    /// Applies `move` to the state, then resumes (outside the lock) every sleeper the new time makes due, in the
    /// order they were queued.
    private func release(_ move: (inout State) -> Void) {
        let toRelease: [Continuation] = state.withLock { current in
            move(&current)
            let (due, remaining) = current.sleepers.reduce(into: ([Sleeper](), [Sleeper]())) { split, sleeper in
                if current.now >= sleeper.deadline { split.0.append(sleeper) } else { split.1.append(sleeper) }
            }
            current.sleepers = remaining
            return due.sorted { $0.id < $1.id }.map(\.continuation)
        }
        for cont in toRelease {
            cont.resume()
        }
    }

    private enum SleepOutcome { case deadlineAlreadyPast, suspended, cancelled }
    private enum WaitOutcome { case queued, satisfied, cancelled }
}

/// Whether the current task was created inside ``TestClock/withUntrackedSleeps(_:)``.
private enum HarnessSleep {
    @TaskLocal static var isActive = false
}

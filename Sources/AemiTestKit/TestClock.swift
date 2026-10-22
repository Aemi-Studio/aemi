import Synchronization

/// A deterministic `Clock` whose time advances only when a test calls `advance(by:)`
/// — generalizing the AD-family's earlier `ManualClock`. Sleepers suspend until time is manually
/// advanced past their deadline, so time-dependent code (relative-time SQL,
/// durability timeouts, server timing) is pinned with *zero* real-time waiting.
///
/// Two improvements over the original: the lock primitive is unified on
/// `Synchronization.Mutex` (the original `ManualClock` used `OSAllocatedUnfairLock`
/// while its siblings used `Mutex`), and `sleeperCount` exposes how many tasks are
/// currently parked — so a test can wait for a sleeper to register before advancing,
/// instead of guessing with a `Task.yield()`. The parked sleepers live in a shared
/// `ContinuationRegistry` (a deadline-ordered heap), so waking the due ones is a few
/// pops rather than a full scan-and-sort, and the park / wake / cancel logic is shared
/// with `AsyncEventProbe` rather than re-rolled here.
public final class TestClock: Clock, Sendable, CustomStringConvertible {
    public struct Instant: InstantProtocol, Sendable {
        /// Elapsed `Duration` since the clock's origin.
        public var offset: Duration

        public init(offset: Duration = .zero) { self.offset = offset }

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

    private typealias Wakes = [(CheckedContinuation<Void, any Error>, Void)]

    private struct State {
        var now: Instant
        var sleepers = ContinuationRegistry<Instant, Void>()
        /// Monotonic count of every `sleep` that has ever parked. Never decreases, so it is the
        /// right baseline for "N *more* sleepers from here" — unlike the live count, which falls
        /// when a sleeper wakes or cancels.
        var registrations: UInt64 = 0
        /// Rendezvous waiters keyed by a target **live** sleeper count.
        var countWaiters = ContinuationRegistry<Int, Void>()
        /// Rendezvous waiters keyed by a target **cumulative registration** count.
        var registrationWaiters = ContinuationRegistry<UInt64, Void>()
        /// Rendezvous waiters keyed by a target **live untracked** sleeper count.
        var untrackedWaiters = ContinuationRegistry<Int, Void>()

        /// Every parked rendezvous wait, whatever it waits for.
        var rendezvousWaiterCount: Int {
            countWaiters.count + registrationWaiters.count + untrackedWaiters.count
        }

        /// Rendezvous waiters share one id sequence; each registry only needs its ids unique.
        private var nextWaiterID: UInt64 = 0

        mutating func makeWaiterID() -> UInt64 {
            defer { nextWaiterID &+= 1 }
            return nextWaiterID
        }

        /// Record that a sleeper just parked and return every rendezvous waiter it satisfies.
        /// Callers must resume the result *outside* the lock.
        mutating func noteRegistration(counted: Bool) -> Wakes {
            guard counted else { return untrackedWaiters.wake(upTo: sleepers.uncountedCount, with: ()) }
            registrations &+= 1
            var woken = countWaiters.wake(upTo: sleepers.count, with: ())
            woken += registrationWaiters.wake(upTo: registrations, with: ())
            return woken
        }
    }

    private let state: Mutex<State>

    public init(now: Instant = Instant()) {
        state = Mutex(State(now: now))
    }

    public var now: Instant { state.withLock { $0.now } }
    public var minimumResolution: Duration { .zero }

    /// How many tasks are currently parked in `sleep`. Lets a test sequence
    /// deterministically: spin until `sleeperCount == N`, then `advance`.
    ///
    /// Sleeps the harness starts for itself — a probe's or a spy's timeout — are *untracked* and left
    /// out (see ``withUntrackedSleeps(_:)``), so only the code under test and the test's own sleepers
    /// satisfy a rendezvous.
    public var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    /// How many untracked sleeps are currently parked: the timeouts of probe and spy waits that were
    /// given this clock. A test that drives such a timeout rendezvouses with it here, then advances.
    public var untrackedSleeperCount: Int { state.withLock { $0.sleepers.uncountedCount } }

    /// The clock's time and what is parked on it, for a failure message: a test that hangs on a
    /// rendezvous can print this to see which deadlines are pending and how many waits are open.
    public var description: String {
        let (now, sleeps, waiters) = state.withLock { ($0.now, $0.sleepers.parkedKeys, $0.rendezvousWaiterCount) }
        let deadlines = sleeps.map { "\($0.key.offset)\($0.counted ? "" : " (untracked)")" }
        return "TestClock(now: \(now.offset), sleepers: [\(deadlines.joined(separator: ", "))], "
            + "rendezvous waiters: \(waiters))"
    }

    /// Heap slots the sleeper queue holds, live or stale. For tests that pin the compaction bound.
    var storedSleeperSlotCount: Int { state.withLock { $0.sleepers.storedSlotCount } }

    public func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        try Task.checkCancellation()
        let id = state.withLock { $0.sleepers.makeID() }
        let counted = !HarnessSleep.isActive
        enum Action { case resumeNow, cancelled, suspended }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                let (action, rendezvous) = state.withLock { s -> (Action, Wakes) in
                    if Task.isCancelled { return (.cancelled, []) }
                    if deadline <= s.now { return (.resumeNow, []) }
                    s.sleepers.park(id: id, key: deadline, continuation, counted: counted)
                    return (.suspended, s.noteRegistration(counted: counted))
                }
                // Release anyone waiting to observe this park, outside the lock.
                for (waiter, _) in rendezvous { waiter.resume() }
                switch action {
                    case .resumeNow: continuation.resume()
                    case .cancelled: continuation.resume(throwing: CancellationError())
                    case .suspended: break
                }
            }
        } onCancel: {
            state.withLock { $0.sleepers.remove(id: id) }?.resume(throwing: CancellationError())
        }
    }

    /// Advance time by `duration`, waking every sleeper whose deadline is now due (in
    /// deadline order). Continuations resume *outside* the lock.
    public func advance(by duration: Duration) {
        release { $0.now = $0.now.advanced(by: duration) }
    }

    /// Advance to a specific instant (no-op if already at or past it).
    ///
    /// The comparison and the move happen under one lock acquisition, so concurrent calls land on the
    /// latest instant instead of each adding its own distance.
    public func advance(to instant: Instant) {
        release { if instant > $0.now { $0.now = instant } }
    }

    /// Applies `move` to the state, then wakes (outside the lock) every sleeper the new time makes due.
    private func release(_ move: (inout State) -> Void) {
        let woken = state.withLock { s -> Wakes in
            move(&s)
            return s.sleepers.wake(upTo: s.now, with: ())
        }
        for (continuation, _) in woken { continuation.resume() }
    }

    /// Suspend until **at least** `count` sleepers are parked, returning immediately if that many
    /// already are.
    ///
    /// This is the one to reach for by default. Because it counts sleepers that parked *before* the
    /// call, it cannot miss a registration that races ahead of it — the classic lost-wakeup that
    /// turns a time test flaky. Replaces the `while clock.sleeperCount < n { await Task.yield() }`
    /// spin that `sleeperCount` alone forces on callers.
    ///
    /// Cancellation unregisters and throws `CancellationError`.
    public func waitForSleepers(atLeast count: Int) async throws {
        try await rendezvous(
            park: { s, id, continuation in
                if s.sleepers.count >= count { return .satisfied }
                s.countWaiters.park(id: id, key: count, continuation)
                return .parked
            },
            unpark: { $0.countWaiters.remove(id: $1) })
    }

    /// A point in the clock's registration history, taken synchronously with ``registrationMark()``
    /// so a later ``waitForSleepers(_:after:)`` counts exactly the sleepers that parked after it,
    /// whichever task runs first.
    public struct RegistrationMark: Sendable, Hashable {
        fileprivate let registrations: UInt64
    }

    /// The current point in the registration history, for ``waitForSleepers(_:after:)``.
    ///
    /// Synchronous, so a test takes it *before* spawning the work whose sleeper it wants to wait for;
    /// the wait itself may then start on any task, in any order, without losing the sleeper.
    public func registrationMark() -> RegistrationMark {
        RegistrationMark(registrations: state.withLock { $0.registrations })
    }

    /// Suspend until `count` sleepers have parked after `mark`, counting one that was cancelled or
    /// woken in the meantime.
    ///
    /// Unlike ``waitForSleepers(atLeast:)``, which observes the live count, this counts registrations,
    /// so it stages a second wave of sleepers while the first is still parked and is never satisfied by
    /// a sleeper that parked before the mark. Unlike ``waitForAdditionalSleepers(_:)``, the baseline is
    /// fixed by the caller, so it cannot be moved by when the awaiting task happens to start.
    ///
    /// - Parameters:
    ///   - count: The number of further registrations to wait for; a non-positive count returns
    ///     immediately.
    ///   - mark: The baseline, from ``registrationMark()``.
    /// - Throws: `CancellationError` if cancelled before the registrations happened.
    public func waitForSleepers(_ count: Int, after mark: RegistrationMark) async throws {
        try Task.checkCancellation()
        guard count > 0 else { return }
        let target = mark.registrations &+ UInt64(count)
        try await rendezvous(
            park: { s, id, continuation in
                if s.registrations >= target { return .satisfied }
                s.registrationWaiters.park(id: id, key: target, continuation)
                return .parked
            },
            unpark: { $0.registrationWaiters.remove(id: $1) })
    }

    /// Suspend until `count` **further** sleepers park, counting only registrations that happen
    /// after this call starts; the same as ``waitForSleepers(_:after:)`` with a mark taken now.
    ///
    /// "Now" is when this call *runs*, not when the task that makes it was created. A wait spawned
    /// alongside the work (`Task { try await clock.waitForAdditionalSleepers(1) }`) can start after
    /// the sleeper it wants has already parked, and then waits for one more that never comes. Take a
    /// ``registrationMark()`` synchronously before spawning the work and use
    /// ``waitForSleepers(_:after:)`` in that case, or rendezvous with the waiter's registration (see
    /// `additionalWaiterCount`) before parking the next sleeper.
    ///
    /// - Parameter count: The number of further registrations; a non-positive count returns
    ///   immediately.
    /// - Throws: `CancellationError` if cancelled before the registrations happened.
    public func waitForAdditionalSleepers(_ count: Int) async throws {
        try await waitForSleepers(count, after: registrationMark())
    }

    /// How many ``waitForSleepers(_:after:)`` calls are parked. A test that starts a
    /// ``waitForAdditionalSleepers(_:)`` in a separate task uses it to know the baseline was taken
    /// before it parks the next sleeper.
    var additionalWaiterCount: Int { state.withLock { $0.registrationWaiters.count } }

    /// How many rendezvous waits of any kind are parked.
    var rendezvousWaiterCount: Int { state.withLock { $0.rendezvousWaiterCount } }

    /// Suspend until **at least** `count` untracked sleeps are parked: the timeout of a probe or spy
    /// wait given this clock. Use it to know a timeout is armed before advancing past it.
    ///
    /// Cancellation unregisters and throws `CancellationError`.
    public func waitForUntrackedSleepers(atLeast count: Int) async throws {
        try await rendezvous(
            park: { s, id, continuation in
                if s.sleepers.uncountedCount >= count { return .satisfied }
                s.untrackedWaiters.park(id: id, key: count, continuation)
                return .parked
            },
            unpark: { $0.untrackedWaiters.remove(id: $1) })
    }

    /// Runs `body` with every `TestClock` sleep that the tasks it *creates* start marked *untracked*.
    ///
    /// An untracked sleep parks and wakes like any other, but is not counted by ``sleeperCount``, does
    /// not satisfy ``waitForSleepers(atLeast:)`` or a registration mark, and is ignored by
    /// ``runToLastSleeper()``. Probe and spy waits use it for their timeouts: the harness's own timer
    /// must not make a rendezvous believe the code under test has reached its `sleep`.
    ///
    /// The marking is a task-local, so it follows the tasks created inside `body` (`Task { }`,
    /// `group.addTask`) and nothing else; `body` itself is synchronous because a task-local scope that
    /// spans a suspension is toolchain-specific.
    ///
    /// ```swift
    /// let timer = TestClock.withUntrackedSleeps { Task { try await clock.sleep(for: .seconds(30)) } }
    /// ```
    public static func withUntrackedSleeps<Result>(_ body: () throws -> Result) rethrows -> Result {
        try HarnessSleep.$isActive.withValue(true, operation: body)
    }

    private typealias Continuation = CheckedContinuation<Void, any Error>

    /// What a rendezvous found when it tried to park.
    private enum Rendezvous { case satisfied, parked }

    /// The shared choreography of every rendezvous wait: reserve an id, then — atomically with the
    /// cancellation check — either find the condition already met or park the continuation, and make
    /// cancellation unregister it and throw. `park` runs under the lock; `unpark` is the cancellation
    /// handler's removal. Continuations resume outside the lock.
    private func rendezvous(
        park: @Sendable (inout State, UInt64, Continuation) -> Rendezvous,
        unpark: @escaping @Sendable (inout State, UInt64) -> Continuation?
    ) async throws {
        try Task.checkCancellation()
        let id = state.withLock { $0.makeWaiterID() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: Continuation) in
                let action = state.withLock { s -> Rendezvous? in
                    Task.isCancelled ? nil : park(&s, id, continuation)
                }
                switch action {
                    case .satisfied: continuation.resume()
                    case nil: continuation.resume(throwing: CancellationError())
                    case .parked: break
                }
            }
        } onCancel: {
            state.withLock { unpark(&$0, id) }?.resume(throwing: CancellationError())
        }
    }

    /// Release everything that is parked — sleepers (tracked or not) and rendezvous waiters — by making
    /// each throw `CancellationError`, and return how many were released. Time does not move.
    ///
    /// Call it at the end of a test whose code under test leaves a sleeper parked on purpose (a loop that
    /// sleeps forever, a timer nobody advances): the parked task then finishes instead of outliving the
    /// test, and no continuation is dropped unresumed. Unlike ``runToLastSleeper()``, which makes the
    /// sleeps *succeed*, this makes them fail, so the code under test sees a cancellation rather than the
    /// time it was waiting for.
    @discardableResult
    public func drain() -> Int {
        let released = state.withLock { s in
            s.sleepers.drain() + s.countWaiters.drain() + s.registrationWaiters.drain()
                + s.untrackedWaiters.drain()
        }
        for continuation in released { continuation.resume(throwing: CancellationError()) }
        return released.count
    }

    /// Wake every parked sleeper by advancing to the furthest pending deadline — the
    /// "drain everything" step at the end of a deterministic time test.
    public func runToLastSleeper() {
        let furthest = state.withLock { $0.sleepers.maxKey }
        if let furthest { advance(to: furthest) }
    }
}

/// Whether the current task was created inside ``TestClock/withUntrackedSleeps(_:)``.
private enum HarnessSleep {
    @TaskLocal static var isActive = false
}

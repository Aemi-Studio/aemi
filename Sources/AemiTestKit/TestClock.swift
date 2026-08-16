import Synchronization

/// A deterministic `Clock` whose time advances only when a test calls `advance(by:)`
/// — generalizing maintastic's `ManualClock`. Sleepers suspend until time is manually
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
public final class TestClock: Clock, Sendable {
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

    private typealias Wakes = [(UnsafeContinuation<Void, any Error>, Void)]

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

        /// Record that a sleeper just parked and return every rendezvous waiter it satisfies.
        /// Callers must resume the result *outside* the lock.
        mutating func noteRegistration() -> Wakes {
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
    public var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    public func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        try Task.checkCancellation()
        let id = state.withLock { $0.sleepers.makeID() }
        enum Action { case resumeNow, cancelled, suspended }
        try await withTaskCancellationHandler {
            try await withUnsafeThrowingContinuation {
                (continuation: UnsafeContinuation<Void, any Error>) in
                let (action, rendezvous) = state.withLock { s -> (Action, Wakes) in
                    if Task.isCancelled { return (.cancelled, []) }
                    if deadline <= s.now { return (.resumeNow, []) }
                    s.sleepers.park(id: id, key: deadline, continuation)
                    return (.suspended, s.noteRegistration())
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
        let woken = state.withLock { s -> [(UnsafeContinuation<Void, any Error>, Void)] in
            s.now = s.now.advanced(by: duration)
            return s.sleepers.wake(upTo: s.now, with: ())
        }
        for (continuation, _) in woken { continuation.resume() }
    }

    /// Advance to a specific instant (no-op if already past it).
    public func advance(to instant: Instant) {
        let delta = state.withLock { $0.now.duration(to: instant) }
        if delta > .zero { advance(by: delta) }
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
        try Task.checkCancellation()
        let id = state.withLock { $0.countWaiters.makeID() }
        enum Action { case satisfied, cancelled, suspended }
        try await withTaskCancellationHandler {
            try await withUnsafeThrowingContinuation {
                (continuation: UnsafeContinuation<Void, any Error>) in
                let action = state.withLock { s -> Action in
                    if Task.isCancelled { return .cancelled }
                    if s.sleepers.count >= count { return .satisfied }
                    s.countWaiters.park(id: id, key: count, continuation)
                    return .suspended
                }
                switch action {
                    case .satisfied: continuation.resume()
                    case .cancelled: continuation.resume(throwing: CancellationError())
                    case .suspended: break
                }
            }
        } onCancel: {
            state.withLock { $0.countWaiters.remove(id: id) }?.resume(throwing: CancellationError())
        }
    }

    /// Suspend until `count` **further** sleepers park, counting only registrations that happen
    /// after this call.
    ///
    /// Use it to stage a fan-out — "let the first wave park, advance, now wait for the second wave"
    /// — where ``waitForSleepers(atLeast:)`` would be satisfied instantly by the sleepers already
    /// present. The trade-off is the mirror image: if the sleepers you are waiting for register
    /// *before* you call this, it waits for that many again and hangs. Prefer the `atLeast` form
    /// unless you specifically need the delta.
    ///
    /// Cancellation unregisters and throws `CancellationError`.
    public func waitForAdditionalSleepers(_ count: Int) async throws {
        try Task.checkCancellation()
        let id = state.withLock { $0.registrationWaiters.makeID() }
        enum Action { case satisfied, cancelled, suspended }
        try await withTaskCancellationHandler {
            try await withUnsafeThrowingContinuation {
                (continuation: UnsafeContinuation<Void, any Error>) in
                let action = state.withLock { s -> Action in
                    if Task.isCancelled { return .cancelled }
                    guard count > 0 else { return .satisfied }
                    // The baseline is read under the same lock as the park, so a registration
                    // cannot slip in between and shift the target.
                    let target = s.registrations &+ UInt64(count)
                    s.registrationWaiters.park(id: id, key: target, continuation)
                    return .suspended
                }
                switch action {
                    case .satisfied: continuation.resume()
                    case .cancelled: continuation.resume(throwing: CancellationError())
                    case .suspended: break
                }
            }
        } onCancel: {
            state.withLock { $0.registrationWaiters.remove(id: id) }?
                .resume(throwing: CancellationError())
        }
    }

    /// Wake every parked sleeper by advancing to the furthest pending deadline — the
    /// "drain everything" step at the end of a deterministic time test.
    public func runToLastSleeper() {
        let furthest = state.withLock { $0.sleepers.maxKey }
        if let furthest { advance(to: furthest) }
    }
}

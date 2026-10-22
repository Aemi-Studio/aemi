import Synchronization
// `public import`: the timeout error + probe init expose Swift Testing's `SourceLocation` publicly.
public import Testing

/// Raised when an `AsyncEventProbe.wait` boundary is not reached before its (clock-driven)
/// timeout. Carries the probe's *creation* site, so a hung test points at the probe
/// rather than at the timeout machinery.
public struct AsyncEventProbeTimeoutError: Error, CustomStringConvertible {
    public let requested: Int
    public let recorded: Int
    public let creation: SourceLocation

    public var description: String {
        "AsyncEventProbe timed out waiting for at least \(requested) event(s); only \(recorded) recorded. "
            + "Probe created at \(creation)."
    }
}

@available(*, deprecated, renamed: "AsyncEventProbeTimeoutError")
public typealias AsyncProbeTimeoutError = AsyncEventProbeTimeoutError

@available(*, deprecated, renamed: "AsyncEventProbe")
public typealias AsyncProbe<Event: Sendable> = AsyncEventProbe<Event>

/// A suspend-until-count event boundary: production code calls `record(_:)` from any
/// isolation; a test `await`s `wait(forAtLeast:)` until enough events land, then
/// inspects `events`. This is genuinely beyond native `Confirmation`, which only
/// *counts within a closure* and can neither suspend-until-a-count, expose the
/// recorded events, nor diagnose a stall.
///
/// Improvement over the port: the timeout is **clock-injectable**. `wait` races the
/// boundary against `clock.sleep`, so under a `TestClock` there is *zero* real-time
/// deadline — the wait only ends when the events arrive or the test advances the
/// clock past the timeout.
public final class AsyncEventProbe<Event: Sendable>: Sendable {
    private struct State {
        var events: [Event] = []
        var waiters = ContinuationRegistry<Int, [Event]?>()
    }

    private enum ThresholdAction {
        case ready([Event])
        case cancelled
        case suspended
    }

    private let state = Mutex(State())
    private let creation: SourceLocation

    public init(sourceLocation: SourceLocation = #_sourceLocation) {
        self.creation = sourceLocation
    }

    /// All events recorded so far — the introspection native `Confirmation` lacks.
    public var events: [Event] { state.withLock { $0.events } }
    public var count: Int { state.withLock { $0.events.count } }

    /// How many waits are parked on a threshold. Lets a test know a wait has registered before it records.
    var waiterCount: Int { state.withLock { $0.waiters.count } }

    /// Record an event, waking every waiter whose threshold is now met. Safe to call from any
    /// isolation.
    ///
    /// A woken waiter is not handed a snapshot of the events: it takes its own copy of the first
    /// `threshold` events once it runs. A snapshot built here would keep the event buffer shared
    /// until the waiter let go of it, so the next `record` would copy the whole array, once per
    /// wake (quadratic over a long stream).
    public func record(_ event: Event) {
        let resumals = state.withLock { s -> [(UnsafeContinuation<[Event]?, any Error>, [Event]?)] in
            s.events.append(event)
            return s.waiters.wake(upTo: s.events.count, with: nil)
        }
        for (continuation, _) in resumals { continuation.resume(returning: nil) }
    }

    /// Suspend until at least `count` events are recorded, racing a `clock`-driven
    /// timeout. Returns the events at the moment the boundary was reached. Under a
    /// `TestClock` the timeout never fires on its own — only the events (or an explicit
    /// `advance`) end the wait.
    public func wait<C: Clock>(
        forAtLeast count: Int,
        within duration: C.Duration,
        clock: C
    ) async throws -> [Event] {
        if count <= 0 { return events }
        let creation = self.creation
        return try await withThrowingTaskGroup(of: [Event].self) { group in
            group.addTask { try await self.waitForThreshold(count) }
            // The timeout is the harness's own timer: a `TestClock` must not count it as a sleeper.
            TestClock.withUntrackedSleeps {
                group.addTask {
                    try await clock.sleep(for: duration)
                    throw AsyncEventProbeTimeoutError(
                        requested: count, recorded: self.count, creation: creation)
                }
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    /// Convenience over `ContinuousClock` with a generous real-time deadline. Prefer
    /// the clock-injectable overload under a `TestClock`.
    public func wait(forAtLeast count: Int, timeout: Duration = .seconds(2)) async throws -> [Event] {
        try await wait(forAtLeast: count, within: timeout, clock: ContinuousClock())
    }

    /// The boundary half: parks until `count` events exist, honoring cancellation
    /// (the timeout cancels it after winning the race).
    ///
    /// A wait that is already satisfied returns every event recorded at that moment; one that had to
    /// park returns exactly the first `count`, the events at the moment the boundary was reached.
    private func waitForThreshold(_ count: Int) async throws -> [Event] {
        let id = state.withLock { $0.waiters.makeID() }
        let ready = try await withTaskCancellationHandler {
            try await withUnsafeThrowingContinuation {
                (continuation: UnsafeContinuation<[Event]?, any Error>) in
                let action = state.withLock { s -> ThresholdAction in
                    if Task.isCancelled { return .cancelled }
                    if s.events.count >= count { return .ready(s.events) }
                    s.waiters.park(id: id, key: count, continuation)
                    return .suspended
                }
                switch action {
                    case .ready(let events): continuation.resume(returning: events)
                    case .cancelled: continuation.resume(throwing: CancellationError())
                    case .suspended: break
                }
            }
        } onCancel: {
            state.withLock { $0.waiters.remove(id: id) }?.resume(throwing: CancellationError())
        }
        if let ready { return ready }
        // A real copy: `Array(events.prefix(count))` may share the buffer when the prefix is all of it, which
        // would make the producer's next append copy the whole array again.
        return state.withLock { s in
            var snapshot: [Event] = []
            snapshot.reserveCapacity(count)
            snapshot.append(contentsOf: s.events[..<count])
            return snapshot
        }
    }
}

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
        var waiters = ContinuationRegistry<Int, [Event]>()
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

    /// Record an event, waking every waiter whose threshold is now met (with a
    /// snapshot of the events at that moment). Safe to call from any isolation.
    public func record(_ event: Event) {
        let resumals = state.withLock { s -> [(UnsafeContinuation<[Event], any Error>, [Event])] in
            s.events.append(event)
            let snapshot = s.events
            return s.waiters.wake(upTo: snapshot.count, with: snapshot)
        }
        for (continuation, snapshot) in resumals { continuation.resume(returning: snapshot) }
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
            group.addTask {
                try await clock.sleep(for: duration)
                throw AsyncEventProbeTimeoutError(
                    requested: count, recorded: self.count, creation: creation)
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
    private func waitForThreshold(_ count: Int) async throws -> [Event] {
        let id = state.withLock { $0.waiters.makeID() }
        return try await withTaskCancellationHandler {
            try await withUnsafeThrowingContinuation {
                (continuation: UnsafeContinuation<[Event], any Error>) in
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
    }
}

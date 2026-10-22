import Synchronization
// `public import`: the timeout error + probe init expose Swift Testing's `SourceLocation` publicly.
public import Testing

/// Raised when an `AsyncEventProbe` wait is not satisfied before its (clock-driven) timeout.
///
/// Carries the probe's label and *creation* site, so a hung test points at the probe rather than at the
/// timeout machinery, and the events recorded so far, so the message shows what did happen. The listing is
/// bounded: at most ``maximumListedEvents`` events, the most recent ones, each cut to
/// ``maximumEventDescriptionLength`` characters.
public struct AsyncEventProbeTimeoutError: Error, Sendable, CustomStringConvertible {
    /// How many recorded events the message lists, newest last.
    public static let maximumListedEvents = 10
    /// How long one listed event's description may be before it is cut with an ellipsis.
    public static let maximumEventDescriptionLength = 120

    /// The probe's label, or the empty string if it has none.
    public let label: String
    /// The number of events the wait required; 0 for a ``AsyncEventProbe/wait(until:within:clock:)`` wait.
    public let requested: Int
    /// The number of events recorded when the wait timed out.
    public let recorded: Int
    /// Where the probe was created.
    public let creation: SourceLocation
    /// Whether the wait was for a condition on the events rather than for a count.
    public let isPredicateWait: Bool
    /// Descriptions of the most recent recorded events, oldest first, each cut to
    /// ``maximumEventDescriptionLength`` characters. Empty for a count-only probe.
    public let recentEvents: [String]
    /// How many older recorded events are not in ``recentEvents``.
    public let omittedEvents: Int

    init(
        label: String, requested: Int, recorded: Int, creation: SourceLocation, isPredicateWait: Bool,
        recentEvents: [String], omittedEvents: Int
    ) {
        self.label = label
        self.requested = requested
        self.recorded = recorded
        self.creation = creation
        self.isPredicateWait = isPredicateWait
        self.recentEvents = recentEvents
        self.omittedEvents = omittedEvents
    }

    public var description: String {
        let name = label.isEmpty ? "AsyncEventProbe" : "AsyncEventProbe '\(label)'"
        let wanted =
            isPredicateWait
            ? "the recorded events to satisfy a condition"
            : "at least \(requested) event(s)"
        var text = "\(name) timed out waiting for \(wanted); "
        text += recorded == 0 ? "nothing was recorded" : "\(recorded) recorded"
        if !recentEvents.isEmpty {
            let firstIndex = recorded - recentEvents.count
            let listed = recentEvents.enumerated().map { "#\(firstIndex + $0.offset) \($0.element)" }
            let earlier = omittedEvents > 0 ? "… \(omittedEvents) earlier event(s) omitted, " : ""
            text += ": [\(earlier)\(listed.joined(separator: ", "))]"
        }
        return text + ". Probe created at \(creation)."
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
/// ## Waiting
///
/// - ``wait(forAtLeast:within:clock:)`` suspends until a number of events is recorded.
/// - ``wait(until:within:clock:)`` suspends until the recorded events satisfy a condition — "the
///   events contain an error", "the last event is `.finished`" — so a test needs no polling loop of its
///   own.
///
/// Both race the boundary against a **clock-injectable** timeout, so under a `TestClock` there is
/// *zero* real-time deadline: the wait ends only when the events arrive or the test advances the clock
/// past the timeout. The overloads without a clock use a `ContinuousClock` and a generous default.
///
/// A wait returns the events at the moment its boundary was reached: a wait that had to suspend returns
/// exactly the events up to its threshold (or, for a condition, up to the first record that made it hold),
/// whatever was recorded after; a wait that was already satisfied returns every event recorded then.
///
/// ## Count-only probes
///
/// When only *how many times* a boundary fired matters, use `AsyncEventProbe<Never>` (written
/// `AsyncEventProbe()` when nothing else fixes the payload type) and the no-argument ``record()``. No
/// payload is stored, ``events`` is always empty, and ``count`` and ``isEmpty`` still work.
///
/// ## Diagnostics
///
/// A probe has a ``label`` and remembers where it was created. A wait that times out throws
/// ``AsyncEventProbeTimeoutError``, whose message names both and lists the most recent recorded events.
///
/// ## Ordering and cancellation
///
/// - Waiters are resumed in ascending threshold order, and in the order they began waiting among equal
///   thresholds. (The tasks then run in whatever order the scheduler picks.)
/// - A wait in a task that is already cancelled throws `CancellationError` at once, even if its boundary
///   was already reached. Cancelling a suspended wait throws `CancellationError` and unregisters it.
/// - Of a timeout and a cancellation that both happen, the error that arrives first is thrown.
///
/// The timeout is the harness's own timer, so under a `TestClock` it is parked *untracked*: it does
/// not count toward `sleeperCount` or satisfy `waitForSleepers`. A test that drives the timeout waits for
/// it with `TestClock.waitForUntrackedSleepers(atLeast:)`.
public final class AsyncEventProbe<Event: Sendable>: Sendable {
    /// The state at some boundary: how many events were recorded, and the events (empty if count-only).
    private struct Snapshot {
        let count: Int
        let events: [Event]
    }

    private struct State {
        /// Events recorded, whether or not a payload was stored.
        var count = 0
        var events: [Event] = []
        /// A woken waiter gets `nil` and takes its own copy; a wait that was already satisfied is handed the
        /// snapshot taken under the lock.
        var waiters = ContinuationRegistry<Int, Snapshot?>()

        /// A real copy of the first `count` events: `Array(events.prefix(count))` may share the buffer when the
        /// prefix is all of it, which would make the producer's next append copy the whole array again. A
        /// count-only probe stores no events, so there is nothing to copy.
        func prefixSnapshot(_ count: Int) -> Snapshot {
            var copy: [Event] = []
            copy.reserveCapacity(min(count, events.count))
            copy.append(contentsOf: events.prefix(count))
            return Snapshot(count: count, events: copy)
        }
    }

    private enum ThresholdAction {
        case ready(Snapshot)
        case cancelled
        case suspended
    }

    private let state = Mutex(State())

    /// The name shown in a timeout message, or the empty string.
    public let label: String
    private let creation: SourceLocation

    // The designated initializer is positional so the labeled convenience initializers — including the
    // count-only one in the `Event == Never` extension — delegate to it without re-resolving to
    // themselves (which would recurse).
    private init(_ label: String, _ creation: SourceLocation) {
        self.label = label
        self.creation = creation
    }

    /// Creates an event probe. For a count-only probe omit the generic argument, as in `AsyncEventProbe()`.
    ///
    /// - Parameters:
    ///   - label: A name shown in a timeout message.
    ///   - sourceLocation: Where the probe is created, reported by a timeout message.
    public convenience init(label: String = "", sourceLocation: SourceLocation = #_sourceLocation) {
        self.init(label, sourceLocation)
    }

    /// All events recorded so far — the introspection native `Confirmation` lacks. Always empty for a
    /// count-only probe.
    public var events: [Event] { state.withLock { $0.events } }

    /// How many events were recorded, whether or not a payload was stored.
    public var count: Int { state.withLock { $0.count } }

    /// Whether nothing has been recorded yet. Accurate for count-only probes too.
    public var isEmpty: Bool { state.withLock { $0.count == 0 } }

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
        wake { s in s.events.append(event) }
    }

    private func wake(_ append: (inout State) -> Void) {
        let resumals = state.withLock { s -> [(CheckedContinuation<Snapshot?, any Error>, Snapshot?)] in
            append(&s)
            s.count += 1
            return s.waiters.wake(upTo: s.count, with: nil)
        }
        for (continuation, _) in resumals { continuation.resume(returning: nil) }
    }

    /// Suspend until at least `count` events are recorded, racing a `clock`-driven
    /// timeout. Returns the events at the moment the boundary was reached. Under a
    /// `TestClock` the timeout never fires on its own — only the events (or an explicit
    /// `advance`) end the wait.
    ///
    /// - Throws: ``AsyncEventProbeTimeoutError`` if `duration` elapses on `clock` first, or
    ///   `CancellationError` if the awaiting task is cancelled.
    @discardableResult
    public func wait<C: Clock>(
        forAtLeast count: Int,
        within duration: C.Duration,
        clock: C
    ) async throws -> [Event] {
        try Task.checkCancellation()
        if count <= 0 { return events }
        return try await race(
            within: duration, clock: clock, requested: count, isPredicateWait: false,
            work: { try await self.waitForThreshold(count).events })
    }

    /// Convenience over `ContinuousClock` with a generous real-time deadline. Prefer
    /// the clock-injectable overload under a `TestClock`.
    @discardableResult
    public func wait(forAtLeast count: Int, timeout: Duration = .seconds(2)) async throws -> [Event] {
        try await wait(forAtLeast: count, within: timeout, clock: ContinuousClock())
    }

    /// Suspend until the recorded events satisfy `condition`, racing a `clock`-driven timeout. Returns the
    /// events at the moment it first held.
    ///
    /// `condition` is first checked against the events recorded so far, then against the events as they were
    /// after each further record, in order, so the result does not depend on how the scheduler interleaves the
    /// producer and the waiter. It runs on the waiting task, outside the probe's lock, so it may read the probe;
    /// it is called once per record, so keep it cheap. A count-only probe has no payloads to inspect: use
    /// ``wait(forAtLeast:within:clock:)``.
    ///
    /// - Throws: ``AsyncEventProbeTimeoutError`` (with `isPredicateWait` set) if `duration` elapses on `clock`
    ///   first, or `CancellationError` if the awaiting task is cancelled.
    @discardableResult
    public func wait<C: Clock>(
        until condition: @escaping @Sendable ([Event]) -> Bool,
        within duration: C.Duration,
        clock: C
    ) async throws -> [Event] {
        try Task.checkCancellation()
        return try await race(
            within: duration, clock: clock, requested: 0, isPredicateWait: true,
            work: { try await self.waitForCondition(condition) })
    }

    /// Convenience over `ContinuousClock` with a generous real-time deadline.
    @discardableResult
    public func wait(
        until condition: @escaping @Sendable ([Event]) -> Bool, timeout: Duration = .seconds(2)
    ) async throws -> [Event] {
        try await wait(until: condition, within: timeout, clock: ContinuousClock())
    }

    /// Races `work` against a timeout on `clock`; the first to finish wins and the other is cancelled.
    private func race<C: Clock>(
        within duration: C.Duration,
        clock: C,
        requested: Int,
        isPredicateWait: Bool,
        work: @escaping @Sendable () async throws -> [Event]
    ) async throws -> [Event] {
        try await withThrowingTaskGroup(of: [Event].self) { group in
            group.addTask { try await work() }
            // The timeout is the harness's own timer: a `TestClock` must not count it as a sleeper.
            TestClock.withUntrackedSleeps {
                group.addTask {
                    try await clock.sleep(for: duration)
                    throw self.timeoutError(requested: requested, isPredicateWait: isPredicateWait)
                }
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private func timeoutError(requested: Int, isPredicateWait: Bool) -> AsyncEventProbeTimeoutError {
        let limit = AsyncEventProbeTimeoutError.maximumListedEvents
        let (count, recent) = state.withLock { ($0.count, Array($0.events.suffix(limit))) }
        let cut = AsyncEventProbeTimeoutError.maximumEventDescriptionLength
        let described = recent.map { event -> String in
            let text = String(describing: event)
            return text.count > cut ? text.prefix(cut - 1) + "…" : text
        }
        return AsyncEventProbeTimeoutError(
            label: label, requested: requested, recorded: count, creation: creation,
            isPredicateWait: isPredicateWait, recentEvents: described, omittedEvents: count - described.count)
    }

    /// The condition half: evaluates `condition` on the events so far and then on each next prefix.
    private func waitForCondition(_ condition: @Sendable ([Event]) -> Bool) async throws -> [Event] {
        var snapshot = state.withLock { Snapshot(count: $0.count, events: $0.events) }
        while !condition(snapshot.events) {
            // Exactly one more event each time, even if several are recorded already, so every prefix is seen.
            snapshot = try await waitForThreshold(snapshot.count + 1, exactPrefix: true)
        }
        return snapshot.events
    }

    /// The boundary half: parks until `count` events exist, honoring cancellation
    /// (the timeout cancels it after winning the race).
    ///
    /// A wait that is already satisfied returns every event recorded at that moment; one that had to
    /// park returns exactly the first `count`, the events at the moment the boundary was reached. With
    /// `exactPrefix` both return exactly the first `count`.
    private func waitForThreshold(_ count: Int, exactPrefix: Bool = false) async throws -> Snapshot {
        let id = state.withLock { $0.waiters.makeID() }
        let ready = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Snapshot?, any Error>) in
                let action = state.withLock { s -> ThresholdAction in
                    if Task.isCancelled { return .cancelled }
                    if s.count >= count {
                        return .ready(
                            exactPrefix ? s.prefixSnapshot(count) : Snapshot(count: s.count, events: s.events))
                    }
                    s.waiters.park(id: id, key: count, continuation)
                    return .suspended
                }
                switch action {
                    case .ready(let snapshot): continuation.resume(returning: snapshot)
                    case .cancelled: continuation.resume(throwing: CancellationError())
                    case .suspended: break
                }
            }
        } onCancel: {
            state.withLock { $0.waiters.remove(id: id) }?.resume(throwing: CancellationError())
        }
        if let ready { return ready }
        return state.withLock { $0.prefixSnapshot(count) }
    }
}

extension AsyncEventProbe where Event == Never {
    /// Creates a count-only probe. Constraining the payload to `Never` is what lets a bare
    /// `AsyncEventProbe()` — with no generic argument — resolve here: when the payload is not otherwise
    /// pinned, this is the only applicable initializer. Event probes still spell their payload, as in
    /// `AsyncEventProbe<Int>()`.
    public convenience init(label: String = "", sourceLocation: SourceLocation = #_sourceLocation) {
        self.init(label, sourceLocation)
    }

    /// Records one occurrence for a count-only probe, waking every waiter whose threshold is now met.
    /// A count-only probe has no callable payload-taking ``record(_:)`` (a `Never` cannot be
    /// constructed), so this is the only way to record, and no payload is stored.
    public func record() {
        wake { _ in }
    }
}

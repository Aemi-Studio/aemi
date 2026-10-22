import Synchronization

/// Typed counter + collector that lets a test wait until a known event boundary has fired
/// `N` times, then introspect what was recorded.
///
/// `CountProbe` replaces ad-hoc counters and `Task.yield()` polling loops in tests. The
/// system-under-test (or a test double) calls ``record(_:)`` whenever an observable effect
/// happens; the test awaits that boundary with ``wait(forAtLeast:timeout:)`` and then asserts
/// on ``events`` / ``count`` / ``isEmpty``.
///
/// It is the app-tier sibling of `AemiTestKit`'s `AsyncEventProbe`, and the two follow the same rules:
/// the wait forms, the timeout error, the ordering and the cancellation behaviour are identical. Two
/// differences remain on purpose: the default timeout is 1 second here, and a wait returns nothing — read
/// ``events`` after it — so that `try await task.value` on a `Task { try await probe.wait(…) }` stays free of
/// an unused-result warning.
///
/// ## Canonical usage
///
/// Wire ``record(_:)`` to the SUT's observable effect, start the work, await the boundary,
/// then assert. No `withThrowingTaskGroup`, no manual timeout task, no `group.next()`
/// versus `group.waitForAll()` subtlety — the probe owns the deadline:
///
/// ```swift
/// let probe = CountProbe<Int>()
/// let producer = NumberStreamer(onEmit: { probe.record($0) })
///
/// producer.start(emitting: [1, 2, 3])   // fire-and-forget async work
/// try await probe.wait(forAtLeast: 3)   // suspends until the 3rd event — or the deadline
///
/// #expect(probe.events == [1, 2, 3])
/// ```
///
/// ## Waiting
///
/// - ``wait(forAtLeast:within:clock:)`` suspends until a number of events is recorded.
/// - ``wait(until:within:clock:)`` suspends until the recorded events satisfy a condition — "the events
///   contain an error", "the last event is `.finished`" — so a test needs no polling loop of its own.
///
/// Both race the boundary against a **clock-injectable** timeout: under a ``TestClock`` there is *zero*
/// real-time deadline, and the wait ends only when the events arrive or the test advances the clock past
/// the timeout. The overloads without a clock use a `ContinuousClock`.
///
/// A condition is checked against the events recorded so far and then against each further prefix in
/// order, so which record satisfied it does not depend on how the scheduler interleaves producer and waiter.
///
/// ## Count-only probes
///
/// When a test only cares *how many* times a boundary fired — not the payloads — construct a bare
/// `CountProbe()` and use the no-argument ``record()`` overload. With no generic argument the
/// payload type resolves to the uninhabited `Never` (see ``init(label:file:function:line:)``), so
/// no `<Never>` is spelled at the call site, the payload-taking ``record(_:)`` cannot be called
/// (there is no `Never` to pass), and ``events`` is provably always empty — count-only is a
/// type-level guarantee and the backing array never grows:
///
/// ```swift
/// let spawns = CountProbe()              // no generic argument; the payload resolves to Never
/// spawns.record()                        // the only way to record; `record(())` cannot compile
/// try await spawns.wait(forAtLeast: 1)
/// ```
///
/// ## Diagnostics
///
/// A probe has a ``label`` and remembers where it was created. A wait that times out throws
/// ``CountProbeTimeoutError``, whose message names both and lists the most recent recorded events,
/// bounded in length.
///
/// ## Ordering and cancellation
///
/// - Waiters are resumed in ascending threshold order, and in the order they began waiting among equal
///   thresholds. (The tasks then run in whatever order the scheduler picks.)
/// - A wait in a task that is already cancelled throws `CancellationError` at once, even if its boundary
///   was already reached. Cancelling a suspended wait throws `CancellationError` and unregisters it.
/// - Of a timeout and a cancellation that both happen, the error that arrives first is thrown.
///
/// The timeout is the harness's own timer, so under a ``TestClock`` it is parked *untracked*: it does not
/// count toward `sleeperCount` or satisfy `waitForSleepers`. A test that drives the timeout waits for it
/// with `TestClock.waitForUntrackedSleepers(atLeast:)`.
///
/// ## Threading
///
/// State lives in a `Mutex<State>` (Synchronization, iOS 18+). The count and the event array are
/// updated under the same lock, so a waiter woken at count `N` always observes `N` recorded
/// events. Continuations are resumed *outside* the lock so a re-entrant resumer cannot deadlock,
/// and cancellation is checked *inside* the lock so a waiter is never orphaned between
/// registration and the cancellation handler.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
public final class CountProbe<Event: Sendable>: Sendable {
    /// The state at some boundary: how many events were recorded, and the events (empty if count-only).
    private struct Snapshot {
        let count: Int
        let events: [Event]
    }

    private struct Waiter {
        let id: UInt64
        let target: Int
        let continuation: CheckedContinuation<Snapshot?, any Error>
    }

    private struct State {
        /// Events recorded, whether or not a payload was stored.
        var count = 0
        var events: [Event] = []
        /// Kept sorted by target, then by the order the waits began.
        var waiters: [Waiter] = []
        var nextWaiterID: UInt64 = 0

        /// A real copy of the first `count` events: `Array(events.prefix(count))` may share the buffer when
        /// the prefix is all of it, which would make the producer's next append copy the whole array again.
        func prefixSnapshot(_ count: Int) -> Snapshot {
            var copy: [Event] = []
            copy.reserveCapacity(min(count, events.count))
            copy.append(contentsOf: events.prefix(count))
            return Snapshot(count: count, events: copy)
        }

        /// Removes and returns, in resume order, every waiter the current count satisfies.
        mutating func takeSatisfiedWaiters() -> [CheckedContinuation<Snapshot?, any Error>] {
            let satisfied = waiters.prefix { $0.target <= count }
            waiters.removeFirst(satisfied.count)
            return satisfied.map(\.continuation)
        }

        mutating func insert(_ waiter: Waiter) {
            let index = waiters.firstIndex { $0.target > waiter.target } ?? waiters.endIndex
            waiters.insert(waiter, at: index)
        }

        mutating func remove(_ id: UInt64) -> CheckedContinuation<Snapshot?, any Error>? {
            guard let index = waiters.firstIndex(where: { $0.id == id }) else { return nil }
            return waiters.remove(at: index).continuation
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
    private let file: StaticString
    private let function: String
    private let line: UInt

    // The designated initializer is positional so the labeled convenience initializers — including
    // the count-only one in the `Event == Never` extension — delegate to it without re-resolving
    // to themselves (which would recurse).
    private init(_ label: String, _ file: StaticString, _ function: String, _ line: UInt) {
        self.label = label
        self.file = file
        self.function = function
        self.line = line
    }

    /// Creates an event probe. For a count-only probe omit the generic argument entirely —
    /// `CountProbe()` resolves to the `Event == Never` initializer.
    ///
    /// - Parameters:
    ///   - label: Optional name surfaced in ``CountProbeTimeoutError`` for easier diagnosis.
    ///   - file: Creation-site file, reported by ``CountProbeTimeoutError`` on timeout.
    ///   - function: Creation-site function, reported by ``CountProbeTimeoutError`` on timeout.
    ///   - line: Creation-site line, reported by ``CountProbeTimeoutError`` on timeout.
    public convenience init(
        label: String = "",
        file: StaticString = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        self.init(label, file, function, line)
    }

    /// Records one event. Wakes any waiter whose target count has been reached.
    ///
    /// A woken waiter is not handed a snapshot of the events: it takes its own copy of the first `target` events
    /// once it runs. A snapshot built here would keep the event buffer shared until the waiter let go of it, so the
    /// next `record` would copy the whole array, once per wake.
    public func record(_ event: Event) {
        wake { $0.events.append(event) }
    }

    private func wake(_ append: (inout State) -> Void) {
        let resumals = state.withLock { state -> [CheckedContinuation<Snapshot?, any Error>] in
            append(&state)
            state.count += 1
            return state.takeSatisfiedWaiters()
        }
        for continuation in resumals { continuation.resume(returning: nil) }
    }

    /// Suspends until at least `count` events have been recorded, racing a `clock`-driven timeout.
    ///
    /// - Parameters:
    ///   - count: The number of recorded events to wait for.
    ///   - duration: How long to wait on `clock` before giving up.
    ///   - clock: The clock the timeout runs on; a ``TestClock`` makes it real-time-free.
    /// - Throws: ``CountProbeTimeoutError`` — reporting the probe's creation site — if the timeout elapses first, or
    ///   `CancellationError` if the awaiting task is cancelled.
    public func wait<C: Clock>(
        forAtLeast count: Int,
        within duration: C.Duration,
        clock: C
    ) async throws {
        try Task.checkCancellation()
        if count <= 0 { return }
        _ = try await race(within: duration, clock: clock, expected: count, isConditionWait: false) {
            try await self.waitForThreshold(count).events
        }
    }

    /// Suspends until at least `count` events have been recorded, or `timeout` elapses on a `ContinuousClock`.
    ///
    /// The probe races the recorded-count boundary against `timeout` internally, so callers
    /// neither spawn a timeout task nor coordinate a task group: a producer that never reaches
    /// the target surfaces as a fast, diagnostic failure rather than a hang. See the type-level
    /// documentation for the canonical drive → wait → assert pattern.
    ///
    /// - Parameters:
    ///   - count: The number of recorded events to wait for.
    ///   - timeout: How long to wait before giving up. Defaults to 1 second.
    /// - Throws: ``CountProbeTimeoutError`` — reporting the probe's creation site — if `timeout`
    ///   elapses first, or `CancellationError` if the awaiting task is cancelled.
    public func wait(
        forAtLeast count: Int,
        timeout: Duration = .seconds(1)
    ) async throws {
        try await wait(forAtLeast: count, within: timeout, clock: ContinuousClock())
    }

    /// Suspends until the recorded events satisfy `condition`, racing a `clock`-driven timeout.
    ///
    /// `condition` is first checked against the events recorded so far, then against the events as they were after
    /// each further record, in order, so the result does not depend on how the scheduler interleaves the producer
    /// and the waiter. It runs on the waiting task, outside the probe's lock, so it may read the probe; it is
    /// called once per record, so keep it cheap. A count-only probe has no payloads to inspect: use
    /// ``wait(forAtLeast:within:clock:)``.
    ///
    /// - Throws: ``CountProbeTimeoutError`` (with `isConditionWait` set) if the timeout elapses first, or
    ///   `CancellationError` if the awaiting task is cancelled.
    public func wait<C: Clock>(
        until condition: @escaping @Sendable ([Event]) -> Bool,
        within duration: C.Duration,
        clock: C
    ) async throws {
        try Task.checkCancellation()
        _ = try await race(within: duration, clock: clock, expected: 0, isConditionWait: true) {
            try await self.waitForCondition(condition)
        }
    }

    /// Suspends until the recorded events satisfy `condition`, or `timeout` elapses on a `ContinuousClock`.
    public func wait(
        until condition: @escaping @Sendable ([Event]) -> Bool,
        timeout: Duration = .seconds(1)
    ) async throws {
        try await wait(until: condition, within: timeout, clock: ContinuousClock())
    }

    /// Captures diagnostic state consistently for a wait that has expired.
    func timeoutError(expected count: Int, isConditionWait: Bool = false) -> CountProbeTimeoutError<Event> {
        state.withLock { state in
            CountProbeTimeoutError(
                label: label, expected: count, recordedCount: state.count, recorded: state.events,
                isConditionWait: isConditionWait, file: file, function: function, line: line)
        }
    }

    /// Races `work` against a timeout on `clock`; the first to finish wins and the other is cancelled.
    private func race<C: Clock>(
        within duration: C.Duration,
        clock: C,
        expected: Int,
        isConditionWait: Bool,
        work: @escaping @Sendable () async throws -> [Event]
    ) async throws -> [Event] {
        try await withThrowingTaskGroup(of: [Event].self) { group in
            group.addTask { try await work() }
            // The timeout is the harness's own timer: a `TestClock` must not count it as a sleeper.
            TestClock.withUntrackedSleeps {
                group.addTask {
                    try await clock.sleep(for: duration)
                    throw self.timeoutError(expected: expected, isConditionWait: isConditionWait)
                }
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
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

    /// The boundary half: parks until `count` events exist, honoring cancellation (the timeout cancels it after
    /// winning the race).
    ///
    /// A wait that is already satisfied returns every event recorded at that moment; one that had to park returns
    /// exactly the first `count`, the events at the moment the boundary was reached. With `exactPrefix` both return
    /// exactly the first `count`.
    private func waitForThreshold(_ count: Int, exactPrefix: Bool = false) async throws -> Snapshot {
        let id = state.withLock { state in
            state.nextWaiterID += 1
            return state.nextWaiterID
        }
        let ready = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Snapshot?, any Error>) in
                // Inspecting `Task.isCancelled` inside the lock closes the race where cancellation could land
                // between the `withTaskCancellationHandler` registration and the waiter insertion: in that
                // window `onCancel` would not see a waiter to remove and the continuation would hang.
                let action = state.withLock { state -> ThresholdAction in
                    if Task.isCancelled { return .cancelled }
                    if state.count >= count {
                        return .ready(
                            exactPrefix
                                ? state.prefixSnapshot(count) : Snapshot(count: state.count, events: state.events))
                    }
                    state.insert(Waiter(id: id, target: count, continuation: continuation))
                    return .suspended
                }
                switch action {
                    case .ready(let snapshot): continuation.resume(returning: snapshot)
                    case .cancelled: continuation.resume(throwing: CancellationError())
                    case .suspended: break
                }
            }
        } onCancel: {
            state.withLock { $0.remove(id) }?.resume(throwing: CancellationError())
        }
        if let ready { return ready }
        return state.withLock { $0.prefixSnapshot(count) }
    }

    /// All events recorded so far. Always empty for a count-only `CountProbe<Never>`.
    public var events: [Event] {
        state.withLock { $0.events }
    }

    /// `true` when nothing has been recorded yet — accurate for both event and count-only probes
    /// (a count-only `CountProbe<Never>` never stores events, so this tracks ``count``, not the
    /// backing array).
    public var isEmpty: Bool {
        state.withLock { $0.count == 0 }
    }

    /// Number of times the probe has recorded, whether or not a payload was stored.
    public var count: Int {
        state.withLock { $0.count }
    }

    /// How many waits are parked on a threshold. Lets a test know a wait has registered before it records.
    var waiterCount: Int {
        state.withLock { $0.waiters.count }
    }
}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
extension CountProbe where Event == Never {
    /// Creates a count-only probe. Constraining the payload to `Never` is what lets a bare
    /// `CountProbe()` — with no generic argument — resolve here: when the payload is not otherwise
    /// pinned, this is the only applicable initializer. Event probes still spell their payload, as
    /// in `CountProbe<Int>()`.
    public convenience init(
        label: String = "",
        file: StaticString = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        self.init(label, file, function, line)
    }

    /// Records one occurrence for a count-only probe. Wakes any waiter whose target count has
    /// been reached. A count-only probe has no callable payload-taking `record(_:)` (you cannot
    /// construct a `Never`), so this is the only way to record and the backing array stays empty.
    public func record() {
        wake { _ in }
    }
}

// MARK: - Error

/// Raised when a ``CountProbe`` wait is not satisfied before its (clock-driven) timeout.
///
/// Carries the probe's label and creation site, so a hung test points at the probe rather than at the timeout
/// machinery, and the events recorded so far (``recorded``). The message lists at most
/// ``maximumListedEvents`` of them, the most recent, each cut to ``maximumEventDescriptionLength`` characters.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
public struct CountProbeTimeoutError<Event: Sendable>: Error, Sendable, CustomStringConvertible {
    /// How many recorded events the message lists, newest last.
    public static var maximumListedEvents: Int { 10 }
    /// How long one listed event's description may be before it is cut with an ellipsis.
    public static var maximumEventDescriptionLength: Int { 120 }

    public let label: String
    /// The number of events the wait required; 0 for a ``CountProbe/wait(until:within:clock:)`` wait.
    public let expected: Int
    public let recordedCount: Int
    /// Every event recorded when the wait timed out (empty for a count-only probe).
    public let recorded: [Event]
    /// Whether the wait was for a condition on the events rather than for a count.
    public let isConditionWait: Bool
    public let file: StaticString
    public let function: String
    public let line: UInt

    init(
        label: String, expected: Int, recordedCount: Int, recorded: [Event], isConditionWait: Bool = false,
        file: StaticString, function: String, line: UInt
    ) {
        self.label = label
        self.expected = expected
        self.recordedCount = recordedCount
        self.recorded = recorded
        self.isConditionWait = isConditionWait
        self.file = file
        self.function = function
        self.line = line
    }

    public var description: String {
        let prefix = label.isEmpty ? "CountProbe" : "CountProbe '\(label)'"
        let wanted = isConditionWait ? "the recorded events to satisfy a condition" : "at least \(expected)"
        var text =
            "\(prefix) timed out at \(file):\(line) (\(function)); "
            + (isConditionWait ? "waiting for \(wanted)" : "expected \(wanted)")
            + ", recorded \(recordedCount)"
        let shown = recorded.suffix(Self.maximumListedEvents)
        if !shown.isEmpty {
            let cut = Self.maximumEventDescriptionLength
            let firstIndex = recordedCount - shown.count
            let listed = shown.enumerated()
                .map { entry -> String in
                    let text = String(describing: entry.element)
                    return "#\(firstIndex + entry.offset) " + (text.count > cut ? text.prefix(cut - 1) + "…" : text)
                }
            let earlier =
                recordedCount > shown.count ? "… \(recordedCount - shown.count) earlier event(s) omitted, " : ""
            text += ": [\(earlier)\(listed.joined(separator: ", "))]"
        }
        return text
    }
}

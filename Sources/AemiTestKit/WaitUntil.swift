// `public import`: the wait's creation site is Swift Testing's `SourceLocation`.
public import Testing

/// Suspends until `condition` is true, looking at it again every `interval` on `clock`.
///
/// For state that announces nothing: a view laid out, a socket's port, a counter kept by code that records no event.
/// Prefer an event when there is one — ``AsyncEventProbe`` recorded by the code, ``waitForObservedState(within:clock:label:sourceLocation:_:)``
/// for `@Observable` state, ``KeyValueProbe`` for key-value observable properties — since a poll can miss a value that
/// came and went between two looks.
///
/// The condition is looked at first without waiting. The deadline is fixed once, from the call. On a ``TestClock`` the
/// looks after the first are the test's to drive: each waits for the clock to move by `interval`.
///
/// - Parameters:
///   - timeout: How long to wait on `clock`, from the call.
///   - interval: How long to wait on `clock` between two looks.
///   - clock: The clock the looks and the deadline run on.
///   - label: Names the wait in a timeout message.
///   - isolation: The caller's actor: the condition runs there.
///   - sourceLocation: Where the wait is written, reported by a timeout message.
///   - condition: The state to wait for.
/// - Throws: ``AsyncEventProbeTimeoutError`` (pointing at the call site, its `recorded` the number of looks) if the
///   condition is still false at the deadline, `CancellationError` if the awaiting task is cancelled, or what
///   `condition` throws.
public func waitUntil<C: Clock>(
    within timeout: C.Duration,
    every interval: C.Duration,
    clock: C,
    label: String = "",
    isolation: isolated (any Actor)? = #isolation,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () async throws -> Bool
) async throws {
    let deadline = clock.now.advanced(by: timeout)
    var looks = 1
    while try await !condition() {
        guard clock.now < deadline else {
            throw AsyncEventProbeTimeoutError(
                label: label.isEmpty ? "polled condition" : label,
                requested: 0,
                recorded: looks,
                creation: sourceLocation,
                isPredicateWait: true,
                recentEvents: [],
                omittedEvents: 0
            )
        }
        try await clock.sleep(for: interval)
        looks += 1
    }
}

/// Suspends until `condition` is true over real time, looking every `interval` (1 ms unless given):
/// ``waitUntil(within:every:clock:label:isolation:sourceLocation:_:)`` on a `ContinuousClock`. The timeout is a hang
/// guard, not a latency assertion, so it is generous by default.
public func waitUntil(
    timeout: Duration = .seconds(30),
    every interval: Duration = .milliseconds(1),
    label: String = "",
    isolation: isolated (any Actor)? = #isolation,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () async throws -> Bool
) async throws {
    try await waitUntil(
        within: timeout,
        every: interval,
        clock: ContinuousClock(),
        label: label,
        sourceLocation: sourceLocation,
        condition
    )
}

// `public import`: the wait's creation site is Swift Testing's `SourceLocation`.
public import Testing

#if canImport(Observation)
    import Observation

    /// Suspends until `condition` is true, re-evaluating it whenever an `@Observable` property it reads changes,
    /// racing a `clock`-driven deadline.
    ///
    /// Every round registers one observation and records a single event when it fires, so cancellation, the
    /// deadline and the registration race are all handled by ``AsyncEventProbe/wait(forAtLeast:within:clock:)``.
    ///
    /// `withObservationTracking` notifies *before* the new value is stored. Resuming the awaiting task only
    /// re-enters the main actor after the mutating code has finished, so the condition always sees the new
    /// state. The condition must only read observable properties, otherwise changes will not wake the waiter.
    ///
    /// The deadline is fixed once: a change that does not make the condition true does not extend it.
    ///
    /// - Parameters:
    ///   - timeout: How long to wait on `clock`, from the call.
    ///   - clock: The clock the deadline runs on; a `TestClock` makes it real-time-free.
    ///   - label: Names the wait in a timeout message; "observed state change" if empty.
    ///   - sourceLocation: Where the wait is written, reported by a timeout message.
    ///   - condition: The state to wait for.
    /// - Throws: ``AsyncEventProbeTimeoutError`` (pointing at the call site) if the condition is still false after
    ///   `timeout`, or `CancellationError` if the awaiting task is cancelled.
    @MainActor
    public func waitForObservedState<C: Clock>(
        within timeout: C.Duration,
        clock: C,
        label: String = "",
        sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            let changed = AsyncEventProbe(
                label: label.isEmpty ? "observed state change" : label, sourceLocation: sourceLocation)
            withObservationTracking {
                _ = condition()
            } onChange: {
                changed.record()
            }
            try await changed.wait(forAtLeast: 1, within: clock.now.duration(to: deadline), clock: clock)
        }
    }

    /// Suspends until `condition` is true over real time: ``waitForObservedState(within:clock:label:sourceLocation:_:)``
    /// on a `ContinuousClock`. The timeout is a hang guard, not a latency assertion, so it is generous by default.
    @MainActor
    public func waitForObservedState(
        timeout: Duration = .seconds(30),
        label: String = "",
        sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: @MainActor () -> Bool
    ) async throws {
        try await waitForObservedState(
            within: timeout, clock: ContinuousClock(), label: label, sourceLocation: sourceLocation, condition)
    }
#endif

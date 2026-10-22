#if canImport(Observation)
    import Observation

    /// Suspends until `condition` is true, re-evaluating it whenever an `@Observable` property it reads changes,
    /// racing a `clock`-driven deadline.
    ///
    /// Every round registers one observation and records a single event when it fires, so cancellation, the
    /// deadline and the registration race are all handled by ``CountProbe/wait(forAtLeast:within:clock:)``.
    ///
    /// `withObservationTracking` notifies *before* the new value is stored. Resuming the awaiting task only
    /// re-enters the main actor after the mutating code has finished, so the condition always sees the new
    /// state. The condition must only read observable properties, otherwise changes will not wake the waiter.
    ///
    /// The deadline is fixed once: a change that does not make the condition true does not extend it.
    ///
    /// - Parameters:
    ///   - timeout: How long to wait on `clock`, from the call.
    ///   - clock: The clock the deadline runs on; a ``TestClock`` makes it real-time-free.
    ///   - label: Names the wait in a timeout message; "observed state change" if empty.
    ///   - file: Call-site file, reported by a timeout error.
    ///   - function: Call-site function, reported by a timeout error.
    ///   - line: Call-site line, reported by a timeout error.
    ///   - condition: The state to wait for.
    /// - Throws: ``CountProbeTimeoutError`` (pointing at the call site) if the condition is still false after
    ///   `timeout`, or `CancellationError` if the awaiting task is cancelled.
    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    @MainActor
    public func waitForObservedState<C: Clock>(
        within timeout: C.Duration,
        clock: C,
        label: String = "",
        file: StaticString = #fileID,
        function: String = #function,
        line: UInt = #line,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            let changed = CountProbe(
                label: label.isEmpty ? "observed state change" : label, file: file, function: function, line: line)
            withObservationTracking {
                _ = condition()
            } onChange: {
                changed.record()
            }
            try await changed.wait(forAtLeast: 1, within: clock.now.duration(to: deadline), clock: clock)
        }
    }

    /// Suspends until `condition` is true over real time: ``waitForObservedState(within:clock:label:file:function:line:_:)``
    /// on a `ContinuousClock`. The timeout is a hang guard, not a latency assertion, so it is generous by default.
    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    @MainActor
    public func waitForObservedState(
        timeout: Duration = .seconds(30),
        label: String = "",
        file: StaticString = #fileID,
        function: String = #function,
        line: UInt = #line,
        _ condition: @MainActor () -> Bool
    ) async throws {
        try await waitForObservedState(
            within: timeout, clock: ContinuousClock(), label: label, file: file, function: function, line: line,
            condition)
    }
#endif

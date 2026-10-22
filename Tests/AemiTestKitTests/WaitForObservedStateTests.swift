import Testing

@testable import AemiTestKit

#if canImport(Observation)
    import Observation

    @Suite(.tags(.concurrency), .timeLimit(.minutes(1)))
    @MainActor
    struct WaitForObservedStateTests {
        @Test
        func `returns immediately when the condition is already true`() async throws {
            let model = Counter(value: 1)

            // A tiny timeout proves the helper does not wait when there is nothing to wait for.
            try await waitForObservedState(timeout: .milliseconds(50)) { model.value == 1 }
        }

        @Test
        func `re-registers the observation across successive changes until the condition is true`() async throws {
            let model = Counter()
            let evaluations = AsyncEventProbe()
            let completed = AsyncEventProbe()
            let waiter = Task {
                try await waitForObservedState {
                    evaluations.record()
                    return model.value >= 3
                }
                completed.record()
            }
            // The waiter owns the main actor from its first evaluation until it suspends, so once this returns
            // it has registered its observation.
            try await evaluations.wait(forAtLeast: 1)

            // Each change fires the one-shot observation once. Missing the re-registration would leave the waiter
            // asleep after the first change, so it would never evaluate the condition again.
            try await change(model, to: 1, awaiting: evaluations)
            try await change(model, to: 2, awaiting: evaluations)
            #expect(completed.isEmpty)

            model.value = 3
            try await completed.wait(forAtLeast: 1)
            try await waiter.value
        }

        @Test
        func `times out under a test clock only when the clock is advanced`() async throws {
            let clock = TestClock()
            let model = Counter()
            let waiter = Task {
                try await waitForObservedState(within: .seconds(30), clock: clock, label: "counter") {
                    model.value == 99
                }
            }
            try await clock.waitForUntrackedSleepers(atLeast: 1)

            clock.advance(by: .seconds(30))

            let error = await #expect(throws: AsyncEventProbeTimeoutError.self) { try await waiter.value }
            #expect(error?.label == "counter")
        }

        @Test
        func `a timeout without a label is named for the observation`() async throws {
            let model = Counter()

            let error = await #expect(throws: AsyncEventProbeTimeoutError.self) {
                try await waitForObservedState(timeout: .milliseconds(50)) { model.value == 99 }
            }

            #expect(error?.label == "observed state change")
        }

        @Test
        func `unrelated changes do not extend the deadline`() async throws {
            let model = Counter()
            let mutator = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(20))
                    model.value += 1
                }
            }
            defer { mutator.cancel() }
            let clock = ContinuousClock()
            let start = clock.now

            await #expect(throws: AsyncEventProbeTimeoutError.self) {
                try await waitForObservedState(timeout: .milliseconds(300)) { model.value < 0 }
            }

            // If every observed change restarted the timeout, the endless stream of changes would keep this waiting.
            #expect(clock.now - start < .seconds(10))
        }

        @Test
        func `throws CancellationError when the waiting task is cancelled`() async throws {
            let model = Counter()
            let evaluations = AsyncEventProbe()
            let waiter = Task {
                try await waitForObservedState(timeout: .seconds(30)) {
                    evaluations.record()
                    return model.value == 99
                }
            }
            try await evaluations.wait(forAtLeast: 1)

            waiter.cancel()

            await #expect(throws: CancellationError.self) { try await waiter.value }
        }

        @Test
        func `throws CancellationError when the task is cancelled before the wait starts`() async throws {
            let model = Counter()
            let waiter = Task {
                try await waitForObservedState(timeout: .seconds(30)) { model.value == 99 }
            }
            waiter.cancel()

            await #expect(throws: CancellationError.self) { try await waiter.value }
        }

        /// Sets the value and waits until the waiter has evaluated its condition again. The waiter registers its
        /// next observation in the same main-actor run as that evaluation, so it is registered once this returns.
        private func change(_ model: Counter, to value: Int, awaiting evaluations: AsyncEventProbe<Never>) async throws
        {
            let target = evaluations.count + 1
            model.value = value
            try await evaluations.wait(forAtLeast: target)
        }
    }

    @Observable
    @MainActor
    private final class Counter {
        var value: Int

        init(value: Int = 0) {
            self.value = value
        }
    }
#endif

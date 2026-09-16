import Testing

@testable import AemiTesting

/// Coverage for the two "further sleepers" rendezvous of `TestClock`: the delta form
/// `waitForAdditionalSleepers(_:)` and the mark form `waitForSleepers(_:after:)`, which the
/// delta form is built on. The mark form is what a test reaches for when the wait cannot be
/// parked before the sleeper it wants registers: the mark is taken synchronously, so no task
/// ordering can shift the baseline.
@Suite("TestClock registration marks")
struct TestClockRegistrationMarkTests {
    private func park(
        _ count: Int, on clock: TestClock, in group: inout ThrowingTaskGroup<Void, any Error>
    ) {
        for _ in 0 ..< count {
            group.addTask {
                try await clock.sleep(until: clock.now.advanced(by: .seconds(60)), tolerance: nil)
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func `a mark counts only sleepers registered after it was taken`() async throws {
        let clock = TestClock()
        let released = AsyncProbe<Void>()
        try await withThrowingTaskGroup(of: Void.self) { group in
            park(2, on: clock, in: &group)
            try await clock.waitForSleepers(count: 2)

            // Two sleepers are queued; the threshold form is satisfied while the mark form
            // still waits, because the mark was taken after both registered.
            let mark = clock.registrationMark()
            try await clock.waitForSleepers(count: 2)
            let waiter = Task {
                try await clock.waitForSleepers(2, after: mark)
                released.send(())
            }
            park(1, on: clock, in: &group)
            try await clock.waitForSleepers(count: 3)
            try released.expectNoBufferedElements()

            park(1, on: clock, in: &group)
            try await waiter.value
            clock.advance(by: .seconds(60))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func `a sleeper that was cancelled still counts as a registration after the mark`() async throws {
        let clock = TestClock()
        let mark = clock.registrationMark()
        let doomed = Task {
            try await clock.sleep(until: clock.now.advanced(by: .seconds(60)), tolerance: nil)
        }
        try await clock.waitForSleepers(count: 1)
        doomed.cancel()
        await #expect(throws: CancellationError.self) { try await doomed.value }
        // The registration happened even though the sleeper left the queue: one after the mark.
        try await clock.waitForSleepers(1, after: mark)
    }

    @Test(.timeLimit(.minutes(1)))
    func `the delta form releases once that many further sleepers registered`() async throws {
        let clock = TestClock()
        try await withThrowingTaskGroup(of: Void.self) { group in
            park(1, on: clock, in: &group)
            try await clock.waitForSleepers(count: 1)
            // Taken from the current task, so the baseline is the one sleeper already queued.
            async let waited: Void = clock.waitForAdditionalSleepers(2)
            park(2, on: clock, in: &group)
            try await waited
            try await clock.waitForSleepers(count: 3)
            clock.advance(by: .seconds(60))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func `a non-positive count returns immediately`() async throws {
        let clock = TestClock()
        try await clock.waitForAdditionalSleepers(0)
        try await clock.waitForAdditionalSleepers(-1)
        try await clock.waitForSleepers(0, after: clock.registrationMark())
    }

    @Test(.timeLimit(.minutes(1)))
    func `a cancelled mark wait throws and unregisters`() async throws {
        let clock = TestClock()
        let mark = clock.registrationMark()
        let waiter = Task { try await clock.waitForSleepers(5, after: mark) }
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }

        // Nothing was left parked: a later sleeper registers and wakes cleanly.
        let gate = TaskGate()
        let sleeper = Task {
            try await clock.sleep(until: clock.now.advanced(by: .milliseconds(10)), tolerance: nil)
            gate.open()
        }
        try await clock.waitForSleepers(count: 1)
        clock.advance(by: .milliseconds(10))
        try await gate.wait()
        try await sleeper.value
    }
}

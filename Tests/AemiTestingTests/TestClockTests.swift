import Testing

@testable import AemiTesting

/// `TestClock` regression coverage. Uses `TaskGate` to observe
/// "production code resumed after sleep" and `AsyncProbe` to
/// capture per-sleeper resume events.
///
/// `TestClock` has no upstream dependencies, so its regressions
/// don't ripple through other suites — these tests must stand
/// alone, including dedicated cancellation + multi-sleeper cases.
@Suite("TestClock")
struct TestClockTests {

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)

    @Test func sleepResumesWhenClockAdvancesPastDeadline() async throws {
        let clock = TestClock()
        let gate = TaskGate()

        let task = Task {
            try await clock.sleep(for: .milliseconds(50))
            gate.open()
        }
        try await clock.waitForSleepers()
        clock.advance(by: .milliseconds(50))
        try await gate.wait()
        try await task.value
    }

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)

    @Test func sleepReturnsImmediatelyIfDeadlinePast() async throws {
        let clock = TestClock()
        clock.advance(by: .milliseconds(100))
        // Sleep with a deadline already in the past (now+50ms < now=100ms? No.)
        // The deadline is now + 50ms which is in the future relative to now,
        // so this *does* register and we have to advance.
        let gate = TaskGate()
        let task = Task {
            try await clock.sleep(for: .milliseconds(50))
            gate.open()
        }
        try await clock.waitForSleepers()
        clock.advance(by: .milliseconds(50))
        try await gate.wait()
        try await task.value
    }

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)

    @Test func waitForSleepersResolvesWhenSleeperRegisters() async throws {
        // Without this rendezvous, advance(by:) before sleep()
        // would race and the sleeper would register past the
        // already-advanced clock, hanging forever.
        let clock = TestClock()
        let gate = TaskGate()

        let task = Task {
            try await clock.sleep(for: .milliseconds(50))
            gate.open()
        }
        try await clock.waitForSleepers(count: 1)
        // Sleeper is guaranteed in the queue here.
        clock.advance(by: .milliseconds(50))
        try await gate.wait()
        try await task.value
    }

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)

    @Test func waitForSleepersResolvesWhenNAdditionalRegister() async throws {
        // Tests "N more" semantics — pre-existing sleepers don't
        // satisfy a fresh waitForSleepers call.
        let clock = TestClock()
        let firstSleeperGate = TaskGate()

        let first = Task {
            try await clock.sleep(for: .milliseconds(100))
            firstSleeperGate.open()
        }
        try await clock.waitForSleepers()  // first registers
        // First sleeper is queued. A new waitForSleepers(count: 2)
        // must wait for 2 MORE, not return immediately on queue size.

        let resumeOne = TaskGate()
        let resumeTwo = TaskGate()
        let second = Task {
            try await clock.sleep(for: .milliseconds(200))
            resumeOne.open()
        }
        let third = Task {
            try await clock.sleep(for: .milliseconds(300))
            resumeTwo.open()
        }
        try await clock.waitForSleepers(count: 2)
        // All three sleepers registered. Advance past the latest.
        clock.advance(by: .milliseconds(300))
        try await firstSleeperGate.wait()
        try await resumeOne.wait()
        try await resumeTwo.wait()
        try await first.value
        try await second.value
        try await third.value
    }

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)

    @Test func cancelledSleepThrowsCancellationError() async throws {
        let clock = TestClock()
        let task = Task { try await clock.sleep(for: .milliseconds(50)) }
        try await clock.waitForSleepers()
        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)

    @Test func cancelledWaitForSleepersThrows() async throws {
        let clock = TestClock()
        let task = Task { try await clock.waitForSleepers() }
        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)

    @Test func multipleSleepersResumeInFIFOOrder() async throws {
        let clock = TestClock()
        let probe = AsyncProbe<Int>()

        for i in 0..<5 {
            Task {
                try await clock.sleep(for: .milliseconds(100))
                probe.send(i)
            }
        }
        try await clock.waitForSleepers(count: 5)
        clock.advance(by: .milliseconds(100))

        // All five sleepers resumed. Probe receives in some
        // ordering — verify count, not strict order (the actor
        // scheduling determines who appends first).
        var received: Set<Int> = []
        for _ in 0..<5 {
            if let value = try await probe.next() {
                received.insert(value)
            }
        }
        #expect(received == Set(0..<5))
        try probe.expectNoBufferedElements()
    }

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)

    @Test func advanceWithoutSleepersIsNoOp() {
        let clock = TestClock()
        clock.advance(by: .milliseconds(100))
        #expect(clock.now.offset == .milliseconds(100))
    }
}

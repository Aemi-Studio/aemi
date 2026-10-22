import Synchronization
import Testing

@testable import AemiTestKit

/// `TestClock`'s mark form of the "further sleepers" rendezvous. The mark is taken synchronously, so no task
/// ordering can shift the baseline: this is what a test reaches for when the wait cannot be parked before the
/// sleeper it wants registers.
@Suite(.tags(.concurrency), .timeLimit(.minutes(1)))
struct TestClockRegistrationMarkTests {
    private func park(
        _ count: Int, on clock: TestClock, in group: inout ThrowingTaskGroup<Void, any Error>
    ) {
        for _ in 0 ..< count {
            group.addTask { try await clock.sleep(until: clock.now.advanced(by: .seconds(60))) }
        }
    }

    @Test
    func `a mark counts only sleepers registered after it was taken`() async throws {
        let clock = TestClock()
        let released = Mutex(false)
        try await withThrowingTaskGroup(of: Void.self) { group in
            park(2, on: clock, in: &group)
            try await clock.waitForSleepers(atLeast: 2)

            // Two sleepers are parked; the threshold form is satisfied while the mark form still waits,
            // because the mark was taken after both registered.
            let mark = clock.registrationMark()
            try await clock.waitForSleepers(atLeast: 2)
            let waiter = Task {
                try await clock.waitForSleepers(2, after: mark)
                released.withLock { $0 = true }
            }
            park(1, on: clock, in: &group)
            try await clock.waitForSleepers(atLeast: 3)
            for _ in 0 ..< 100 { await Task.yield() }
            #expect(!released.withLock { $0 }, "one registration after the mark is not two")

            park(1, on: clock, in: &group)
            try await waiter.value
            clock.runToLastSleeper()
        }
    }

    /// The scenario the delta form cannot express: the wait starts on another task *after* the work has
    /// already parked its sleeper. The mark was taken first, so the sleeper still counts.
    @Test
    func `a wait that starts after the sleeper registered still counts it`() async throws {
        let clock = TestClock()
        let mark = clock.registrationMark()
        let worker = Task { try await clock.sleep(until: clock.now.advanced(by: .seconds(60))) }
        try await clock.waitForSleepers(atLeast: 1)

        let waiter = Task { try await clock.waitForSleepers(1, after: mark) }

        try await waiter.value
        clock.runToLastSleeper()
        try await worker.value
    }

    @Test
    func `a sleeper that was cancelled still counts as a registration after the mark`() async throws {
        let clock = TestClock()
        let mark = clock.registrationMark()
        let doomed = Task { try await clock.sleep(until: clock.now.advanced(by: .seconds(60))) }
        try await clock.waitForSleepers(atLeast: 1)
        doomed.cancel()
        await #expect(throws: CancellationError.self) { try await doomed.value }

        // The registration happened even though the sleeper left the queue: one after the mark.
        try await clock.waitForSleepers(1, after: mark)
    }

    @Test
    func `the delta form releases once that many further sleepers registered`() async throws {
        let clock = TestClock()
        try await withThrowingTaskGroup(of: Void.self) { group in
            park(1, on: clock, in: &group)
            try await clock.waitForSleepers(atLeast: 1)
            let waiter = Task { try await clock.waitForAdditionalSleepers(2) }
            while clock.additionalWaiterCount < 1 { await Task.yield() }

            park(2, on: clock, in: &group)

            try await waiter.value
            try await clock.waitForSleepers(atLeast: 3)
            clock.runToLastSleeper()
        }
    }

    @Test
    func `a non-positive count returns immediately`() async throws {
        let clock = TestClock()
        try await clock.waitForAdditionalSleepers(0)
        try await clock.waitForAdditionalSleepers(-1)
        try await clock.waitForSleepers(0, after: clock.registrationMark())
        #expect(clock.additionalWaiterCount == 0)
    }

    @Test
    func `a cancelled mark wait throws and unregisters`() async throws {
        let clock = TestClock()
        let mark = clock.registrationMark()
        let waiter = Task { try await clock.waitForSleepers(5, after: mark) }
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(clock.additionalWaiterCount == 0)

        // Nothing was left parked: a later sleeper registers and wakes cleanly.
        let sleeper = Task { try await clock.sleep(until: clock.now.advanced(by: .milliseconds(10))) }
        try await clock.waitForSleepers(atLeast: 1)
        clock.advance(by: .milliseconds(10))
        try await sleeper.value
    }
}

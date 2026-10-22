import Synchronization
import Testing

@testable import AemiTestKit

/// The harness's own timers (a probe's or spy's timeout) share the clock with the code under test, so they
/// are parked *untracked*: counted by neither `sleeperCount`, the sleeper rendezvous nor registration marks.
/// Counting them let a rendezvous return before the code under test reached its `sleep`.
@Suite(.tags(.concurrency), .timeLimit(.minutes(1)))
struct TestClockUntrackedSleepTests {
    @Test
    func `a probe's timeout does not count as a sleeper`() async throws {
        let clock = TestClock()
        let probe = AsyncEventProbe<Int>()
        let waiter = Task { try await probe.wait(forAtLeast: 1, within: .seconds(60), clock: clock) }

        try await clock.waitForUntrackedSleepers(atLeast: 1)

        #expect(clock.sleeperCount == 0, "the timeout is the harness's timer, not the code under test's")
        #expect(clock.untrackedSleeperCount == 1)
        probe.record(1)
        #expect(try await waiter.value == [1])
    }

    @Test
    func `a sleeper rendezvous is not satisfied by a probe's timeout`() async throws {
        let clock = TestClock()
        let probe = AsyncEventProbe<Int>()
        let timeout = Task { try await probe.wait(forAtLeast: 1, within: .seconds(60), clock: clock) }
        try await clock.waitForUntrackedSleepers(atLeast: 1)

        let satisfied = Mutex(false)
        let rendezvous = Task {
            try await clock.waitForSleepers(atLeast: 1)
            satisfied.withLock { $0 = true }
        }
        for _ in 0 ..< 100 { await Task.yield() }
        #expect(!satisfied.withLock { $0 }, "only the timeout is parked")

        let production = Task { try await clock.sleep(until: clock.now.advanced(by: .seconds(5))) }
        try await rendezvous.value
        #expect(clock.sleeperCount == 1)

        clock.runToLastSleeper()
        try await production.value
        probe.record(1)
        _ = try await timeout.value
    }

    @Test
    func `an untracked sleep wakes with the clock like any other`() async throws {
        let clock = TestClock()
        let woke = AsyncEventProbe<Int>()
        let sleepers = [1, 2]
            .map { seconds in
                TestClock.withUntrackedSleeps {
                    Task {
                        try await clock.sleep(until: clock.now.advanced(by: .seconds(seconds)))
                        woke.record(seconds)
                    }
                }
            }
        try await clock.waitForUntrackedSleepers(atLeast: 2)

        clock.advance(by: .seconds(1))
        _ = try await woke.wait(forAtLeast: 1)
        #expect(woke.events == [1])
        #expect(clock.untrackedSleeperCount == 1)

        clock.advance(by: .seconds(1))
        _ = try await woke.wait(forAtLeast: 2)
        for sleeper in sleepers { try await sleeper.value }
        #expect(clock.untrackedSleeperCount == 0)
    }

    @Test
    func `untracked sleeps are ignored by registration marks and by runToLastSleeper`() async throws {
        let clock = TestClock()
        let mark = clock.registrationMark()
        let untracked = TestClock.withUntrackedSleeps {
            Task { try await clock.sleep(until: clock.now.advanced(by: .seconds(100))) }
        }
        try await clock.waitForUntrackedSleepers(atLeast: 1)

        let counted = Mutex(false)
        let afterMark = Task {
            try await clock.waitForSleepers(1, after: mark)
            counted.withLock { $0 = true }
        }
        for _ in 0 ..< 100 { await Task.yield() }
        #expect(!counted.withLock { $0 }, "an untracked park is not a registration")

        // Nothing tracked is parked, so there is nothing to run to: the harness timer stays armed.
        clock.runToLastSleeper()
        #expect(clock.now.offset == .zero)
        #expect(clock.untrackedSleeperCount == 1)

        let production = Task { try await clock.sleep(until: clock.now.advanced(by: .seconds(5))) }
        try await afterMark.value
        clock.runToLastSleeper()
        try await production.value
        #expect(clock.now.offset == .seconds(5))
        untracked.cancel()
        await #expect(throws: CancellationError.self) { try await untracked.value }
    }

    @Test
    func `waitForUntrackedSleepers returns when satisfied and throws when cancelled`() async throws {
        let clock = TestClock()
        let parked = TestClock.withUntrackedSleeps {
            Task { try await clock.sleep(until: clock.now.advanced(by: .seconds(5))) }
        }
        try await clock.waitForUntrackedSleepers(atLeast: 1)
        try await clock.waitForUntrackedSleepers(atLeast: 1)  // already satisfied: no suspension

        let waiter = Task { try await clock.waitForUntrackedSleepers(atLeast: 2) }
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }

        clock.advance(by: .seconds(5))
        try await parked.value
    }
}

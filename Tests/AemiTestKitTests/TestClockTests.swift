import Synchronization
import Testing

@testable import AemiTestKit

/// Basic `TestClock` behaviour: sleeping, advancing, cancellation and the single-sleeper
/// rendezvous. The two-rendezvous distinction lives in `TestClockRendezvousTests`.
@Suite(.tags(.concurrency), .timeLimit(.minutes(1)))
struct TestClockTests {
    @Test
    func `sleep resumes after the clock advances past the deadline`() async throws {
        let clock = TestClock()
        let woke = AsyncEventProbe<Void>()
        let sleeper = Task {
            try await clock.sleep(until: clock.now.advanced(by: .milliseconds(100)))
            woke.record(())
        }
        try await clock.waitForSleepers(atLeast: 1)

        clock.advance(by: .milliseconds(150))

        try await sleeper.value
        #expect(woke.count == 1)
        #expect(clock.sleeperCount == 0)
    }

    @Test
    func `sleep with a deadline already passed returns without parking`() async throws {
        let clock = TestClock()
        clock.advance(by: .seconds(10))

        try await clock.sleep(until: TestClock.Instant(offset: .seconds(1)))

        #expect(clock.sleeperCount == 0)
    }

    @Test
    func `a sleep that has not reached its deadline stays parked`() async throws {
        let clock = TestClock()
        let sleeper = Task { try await clock.sleep(until: clock.now.advanced(by: .seconds(10))) }
        try await clock.waitForSleepers(atLeast: 1)

        clock.advance(by: .seconds(9))
        #expect(clock.sleeperCount == 1)
        clock.advance(by: .zero)
        #expect(clock.sleeperCount == 1)

        clock.advance(by: .seconds(1))
        try await sleeper.value
        #expect(clock.sleeperCount == 0)
    }

    @Test
    func `cancelling a parked sleeper throws CancellationError and unregisters it`() async throws {
        let clock = TestClock()
        let sleeper = Task { try await clock.sleep(until: clock.now.advanced(by: .seconds(60))) }
        try await clock.waitForSleepers(atLeast: 1)

        sleeper.cancel()

        await #expect(throws: CancellationError.self) { try await sleeper.value }
        #expect(clock.sleeperCount == 0)
    }

    @Test
    func `a sleep started in a cancelled task throws without parking`() async {
        let clock = TestClock()
        let sleeper = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await clock.sleep(until: clock.now.advanced(by: .seconds(60)))
        }

        await #expect(throws: CancellationError.self) { try await sleeper.value }
        #expect(clock.sleeperCount == 0)
    }

    /// Cancellation racing the registration must never leave a continuation parked: the check and the
    /// park are atomic under the clock's lock. Cancelling after zero or one yield lands before, during
    /// or just after the park across iterations.
    @Test
    func `a sleep cancelled around its registration always throws CancellationError`() async {
        for iteration in 0 ..< 500 {
            let clock = TestClock()
            let sleeper = Task { try await clock.sleep(until: clock.now.advanced(by: .seconds(60))) }
            if iteration.isMultiple(of: 2) { await Task.yield() }
            sleeper.cancel()

            await #expect(throws: CancellationError.self) { try await sleeper.value }
            #expect(clock.sleeperCount == 0)
        }
    }

    @Test
    func `sleepers wake in deadline order`() async throws {
        let clock = TestClock()
        let order = AsyncEventProbe<Int>()
        let sleepers = [300, 100, 200]
            .map { milliseconds in
                Task {
                    try await clock.sleep(until: clock.now.advanced(by: .milliseconds(milliseconds)))
                    order.record(milliseconds)
                }
            }
        try await clock.waitForSleepers(atLeast: 3)

        // One deadline at a time, so each wake is observed before the next: the order is the clock's,
        // not the scheduler's.
        for step in 1 ... 3 {
            clock.advance(by: .milliseconds(100))
            _ = try await order.wait(forAtLeast: step)
        }

        for sleeper in sleepers { try await sleeper.value }
        #expect(order.events == [100, 200, 300])
    }

    @Test
    func `one advance wakes every due sleeper and leaves the rest`() async throws {
        let clock = TestClock()
        let woke = AsyncEventProbe<Int>()
        let sleepers = [100, 200, 900]
            .map { milliseconds in
                Task {
                    try await clock.sleep(until: clock.now.advanced(by: .milliseconds(milliseconds)))
                    woke.record(milliseconds)
                }
            }
        try await clock.waitForSleepers(atLeast: 3)

        clock.advance(by: .milliseconds(250))

        let events = try await woke.wait(forAtLeast: 2)
        #expect(Set(events) == [100, 200])
        #expect(clock.sleeperCount == 1)
        clock.runToLastSleeper()
        for sleeper in sleepers { try await sleeper.value }
    }

    @Test
    func `advance to an instant moves time forward and ignores a past instant`() {
        let clock = TestClock()

        clock.advance(to: TestClock.Instant(offset: .seconds(5)))
        #expect(clock.now.offset == .seconds(5))

        clock.advance(to: TestClock.Instant(offset: .seconds(2)))
        #expect(clock.now.offset == .seconds(5), "advancing to the past is a no-op")
    }

    @Test
    func `runToLastSleeper wakes every parked sleeper`() async throws {
        let clock = TestClock()
        let sleepers = [10, 20, 30]
            .map { seconds in
                Task { try await clock.sleep(until: clock.now.advanced(by: .seconds(seconds))) }
            }
        try await clock.waitForSleepers(atLeast: 3)

        clock.runToLastSleeper()

        for sleeper in sleepers { try await sleeper.value }
        #expect(clock.sleeperCount == 0)
        #expect(clock.now.offset == .seconds(30))
    }

    @Test
    func `waitForSleepers suspends until a sleeper registers`() async throws {
        let clock = TestClock()
        let resumed = Mutex(false)
        let waiter = Task {
            try await clock.waitForSleepers(atLeast: 1)
            resumed.withLock { $0 = true }
        }
        for _ in 0 ..< 50 { await Task.yield() }
        #expect(!resumed.withLock { $0 }, "no sleeper has registered yet")

        let sleeper = Task { try await clock.sleep(until: clock.now.advanced(by: .seconds(60))) }

        try await waiter.value
        #expect(resumed.withLock { $0 })
        clock.runToLastSleeper()
        try await sleeper.value
    }

    @Test
    func `waitForSleepers throws when the waiting task is cancelled`() async {
        let clock = TestClock()
        let waiter = Task { try await clock.waitForSleepers(atLeast: 2) }
        waiter.cancel()

        await #expect(throws: CancellationError.self) { try await waiter.value }
    }
}

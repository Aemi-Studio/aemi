import Synchronization
import Testing

@testable import AemiTesting

/// The parts of `TestClock` that mirror `AemiTestKit`'s clock: the live count, `advance(to:)`, `runToLastSleeper`,
/// `drain` and untracked sleeps, so a test reads the same against either.
@Suite("TestClock parity", .timeLimit(.minutes(1)))
struct TestClockParityTests {
    private func park(_ seconds: Int, on clock: TestClock) -> Task<Void, any Error> {
        Task { try await clock.sleep(until: clock.now.advanced(by: .seconds(seconds)), tolerance: nil) }
    }

    @Test func `sleeperCount tracks parked sleepers`() async throws {
        let clock = TestClock()
        #expect(clock.sleeperCount == 0)
        let first = park(10, on: clock)
        let second = park(20, on: clock)
        try await clock.waitForSleepers(atLeast: 2)
        #expect(clock.sleeperCount == 2)

        clock.advance(by: .seconds(10))
        try await first.value
        #expect(clock.sleeperCount == 1)

        first.cancel()
        second.cancel()
        await #expect(throws: CancellationError.self) { try await second.value }
        #expect(clock.sleeperCount == 0)
    }

    @Test func `a sleep cancelled around its registration always throws CancellationError`() async {
        for iteration in 0 ..< 500 {
            let clock = TestClock()
            let sleeper = park(60, on: clock)
            if iteration.isMultiple(of: 2) { await Task.yield() }
            sleeper.cancel()

            await #expect(throws: CancellationError.self) { try await sleeper.value }
            #expect(clock.sleeperCount == 0)
        }
    }

    @Test func `advance to an instant moves time forward and ignores a past instant`() {
        let clock = TestClock()

        clock.advance(to: TestClock.Instant(offset: .seconds(5)))
        #expect(clock.now.offset == .seconds(5))

        clock.advance(to: TestClock.Instant(offset: .seconds(2)))
        #expect(clock.now.offset == .seconds(5), "advancing to the past is a no-op")
    }

    @Test func `advance to an instant wakes the sleepers that are due`() async throws {
        let clock = TestClock()
        let due = park(5, on: clock)
        let later = park(50, on: clock)
        try await clock.waitForSleepers(atLeast: 2)

        clock.advance(to: TestClock.Instant(offset: .seconds(5)))

        try await due.value
        #expect(clock.sleeperCount == 1)
        later.cancel()
        _ = await later.result
    }

    @Test func `concurrent advances to the same instant land on that instant`() async {
        let target = TestClock.Instant(offset: .seconds(1))
        for _ in 0 ..< 500 {
            let clock = TestClock()
            await withTaskGroup(of: Void.self) { group in
                for _ in 0 ..< 16 { group.addTask { clock.advance(to: target) } }
            }
            #expect(clock.now == target)
        }
    }

    @Test func `runToLastSleeper wakes every parked sleeper`() async throws {
        let clock = TestClock()
        let sleepers = [10, 20, 30].map { park($0, on: clock) }
        try await clock.waitForSleepers(atLeast: 3)

        clock.runToLastSleeper()

        for sleeper in sleepers { try await sleeper.value }
        #expect(clock.sleeperCount == 0)
        #expect(clock.now.offset == .seconds(30))
    }

    // MARK: drain

    @Test func `drain makes every parked sleeper throw CancellationError and leaves time alone`() async throws {
        let clock = TestClock()
        let sleepers = [10, 20, 30].map { park($0, on: clock) }
        try await clock.waitForSleepers(atLeast: 3)

        #expect(clock.drain() == 3)

        for sleeper in sleepers { await #expect(throws: CancellationError.self) { try await sleeper.value } }
        #expect(clock.sleeperCount == 0)
        #expect(clock.now.offset == .zero)
    }

    @Test func `drain releases rendezvous waiters too`() async throws {
        let clock = TestClock()
        let mark = clock.registrationMark()
        let byCount = Task { try await clock.waitForSleepers(count: 5) }
        let byMark = Task { try await clock.waitForSleepers(5, after: mark) }
        let sleeper = park(60, on: clock)
        try await clock.waitForSleepers(atLeast: 1)
        // Both waiters are queued once the clock holds them; the sleeper rendezvous above only orders the sleeper.
        while clock.description.contains("rendezvous waiters: 0") { await Task.yield() }
        while !clock.description.contains("rendezvous waiters: 2") { await Task.yield() }

        #expect(clock.drain() == 3)

        for task in [byCount, byMark, sleeper] {
            await #expect(throws: CancellationError.self) { try await task.value }
        }
    }

    @Test func `drain on an idle clock releases nothing`() {
        #expect(TestClock().drain() == 0)
    }

    @Test func `the description lists what is parked`() async throws {
        let clock = TestClock()
        let sleeper = park(7, on: clock)
        try await clock.waitForSleepers(atLeast: 1)

        #expect(clock.description.contains("7.0 seconds"))
        clock.drain()
        _ = await sleeper.result
        #expect(clock.description.contains("sleepers: []"))
    }

    // MARK: untracked sleeps

    @Test func `an untracked sleep wakes with the clock but is not counted`() async throws {
        let clock = TestClock()
        let timer = TestClock.withUntrackedSleeps {
            Task { try await clock.sleep(until: clock.now.advanced(by: .seconds(5)), tolerance: nil) }
        }
        try await clock.waitForUntrackedSleepers(atLeast: 1)
        #expect(clock.sleeperCount == 0)
        #expect(clock.untrackedSleeperCount == 1)

        let satisfied = Mutex(false)
        let rendezvous = Task {
            try await clock.waitForSleepers(atLeast: 1)
            satisfied.withLock { $0 = true }
        }
        for _ in 0 ..< 100 { await Task.yield() }
        #expect(!satisfied.withLock { $0 }, "an untracked park does not satisfy a sleeper rendezvous")

        clock.advance(by: .seconds(5))
        try await timer.value
        #expect(clock.untrackedSleeperCount == 0)
        rendezvous.cancel()
        _ = await rendezvous.result
    }

    @Test func `untracked sleeps are ignored by registration marks and by runToLastSleeper`() async throws {
        let clock = TestClock()
        let mark = clock.registrationMark()
        let untracked = TestClock.withUntrackedSleeps {
            Task { try await clock.sleep(until: clock.now.advanced(by: .seconds(100)), tolerance: nil) }
        }
        try await clock.waitForUntrackedSleepers(atLeast: 1)

        clock.runToLastSleeper()
        #expect(clock.now.offset == .zero, "nothing tracked is parked, so there is nothing to run to")

        let counted = Mutex(false)
        let afterMark = Task {
            try await clock.waitForSleepers(1, after: mark)
            counted.withLock { $0 = true }
        }
        for _ in 0 ..< 100 { await Task.yield() }
        #expect(!counted.withLock { $0 })

        let production = park(5, on: clock)
        try await afterMark.value
        clock.runToLastSleeper()
        try await production.value
        untracked.cancel()
        await #expect(throws: CancellationError.self) { try await untracked.value }
    }

    @Test func `waitForUntrackedSleepers throws when cancelled`() async {
        let clock = TestClock()
        let waiter = Task { try await clock.waitForUntrackedSleepers(atLeast: 1) }
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
    }
}

import Synchronization
import Testing

@testable import AemiTestKit

/// Coverage for `TestClock`'s two sleeper rendezvous. They exist as a pair on purpose, so the tests
/// that matter most are the ones proving they are *not* interchangeable: given identical state,
/// `waitForSleepers(atLeast:)` returns and `waitForAdditionalSleepers(_:)` keeps waiting.
///
/// Every test carries a `.timeLimit` — the failure mode for a rendezvous is "never resumes", which
/// without a deadline hangs the suite instead of failing it.
@Suite(.tags(.concurrency))
struct TestClockRendezvousTests {
    /// Park `count` sleepers far enough out that only an explicit `advance` can wake them.
    private func parkSleepers(_ count: Int, on clock: TestClock, in group: inout TaskGroup<Void>) {
        for _ in 0 ..< count {
            group.addTask { try? await clock.sleep(until: clock.now.advanced(by: .seconds(60))) }
        }
    }

    private func parkSleepers(
        _ count: Int, on clock: TestClock, in group: inout ThrowingTaskGroup<Void, any Error>
    ) {
        for _ in 0 ..< count {
            group.addTask { try? await clock.sleep(until: clock.now.advanced(by: .seconds(60))) }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func `atLeast returns immediately when the sleepers are already parked`() async throws {
        let clock = TestClock()
        await withTaskGroup(of: Void.self) { group in
            parkSleepers(2, on: clock, in: &group)
            // Rendezvous with the parks using the primitive under test.
            try? await clock.waitForSleepers(atLeast: 2)
            #expect(clock.sleeperCount == 2)

            // Already satisfied — must not suspend, even though nothing new will ever park.
            try? await clock.waitForSleepers(atLeast: 1)
            try? await clock.waitForSleepers(atLeast: 2)

            clock.runToLastSleeper()
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func `atLeast resumes when a later sleeper reaches the target`() async throws {
        let clock = TestClock()
        await withTaskGroup(of: Void.self) { group in
            parkSleepers(1, on: clock, in: &group)
            try? await clock.waitForSleepers(atLeast: 1)

            // Target not yet met, so this genuinely suspends until the second sleeper parks.
            group.addTask { try? await clock.waitForSleepers(atLeast: 2) }
            parkSleepers(1, on: clock, in: &group)

            try? await clock.waitForSleepers(atLeast: 2)
            #expect(clock.sleeperCount == 2)
            clock.runToLastSleeper()
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func `additional ignores sleepers that parked before the call`() async throws {
        let clock = TestClock()
        try await withThrowingTaskGroup(of: Void.self) { group in
            parkSleepers(2, on: clock, in: &group)
            try? await clock.waitForSleepers(atLeast: 2)

            // THE DISTINCTION: two sleepers are already parked. `atLeast: 2` is satisfied; this
            // must still wait, because it counts only registrations after this point.
            let released = Mutex(false)
            let waiter = Task {
                try await clock.waitForAdditionalSleepers(2)
                released.withLock { $0 = true }
            }
            parkSleepers(1, on: clock, in: &group)
            try? await clock.waitForSleepers(atLeast: 3)

            // Give it every chance to resume if it were going to, then assert it did not: one
            // further registration is not two. (`atLeast: 2` would have returned long ago.)
            for _ in 0 ..< 100 {
                await Task.yield()
            }
            #expect(!released.withLock { $0 })

            parkSleepers(1, on: clock, in: &group)
            try await waiter.value  // the second further registration releases it
            #expect(released.withLock { $0 })
            #expect(clock.sleeperCount == 4)
            clock.runToLastSleeper()
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func `additional with a non-positive count returns immediately`() async throws {
        let clock = TestClock()
        try await clock.waitForAdditionalSleepers(0)
        try await clock.waitForAdditionalSleepers(-1)
        #expect(clock.sleeperCount == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func `a cancelled rendezvous throws and unregisters`() async throws {
        let clock = TestClock()
        let byCount = Task { try await clock.waitForSleepers(atLeast: 5) }
        let byDelta = Task { try await clock.waitForAdditionalSleepers(5) }

        byCount.cancel()
        byDelta.cancel()
        await #expect(throws: CancellationError.self) { try await byCount.value }
        await #expect(throws: CancellationError.self) { try await byDelta.value }

        // Neither left a parked continuation behind: a later sleeper still parks cleanly.
        await withTaskGroup(of: Void.self) { group in
            parkSleepers(1, on: clock, in: &group)
            try? await clock.waitForSleepers(atLeast: 1)
            #expect(clock.sleeperCount == 1)
            clock.runToLastSleeper()
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func `a cancelled sleeper lowers the live count but not the registration baseline`() async throws {
        let clock = TestClock()
        let doomed = Task { try await clock.sleep(until: clock.now.advanced(by: .seconds(60))) }
        try await clock.waitForSleepers(atLeast: 1)

        doomed.cancel()
        await #expect(throws: CancellationError.self) { try await doomed.value }
        #expect(clock.sleeperCount == 0)  // live count fell back

        // The cumulative baseline did NOT fall back, so "one more" means one genuinely new park.
        try await withThrowingTaskGroup(of: Void.self) { group in
            let waiter = Task { try await clock.waitForAdditionalSleepers(1) }
            parkSleepers(1, on: clock, in: &group)
            try await waiter.value
            clock.runToLastSleeper()
        }
    }
}

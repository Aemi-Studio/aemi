// `import AemiTestKitSeams` (which `@_exported import AemiRuntime`) makes the `TaskProvider`
// members — `task(role:…)` and the `.observation` role — visible under `MemberImportVisibility`.
import AemiTestKitSeams
import Testing

@testable import AemiTestKit

@Suite(.tags(.concurrency))
struct PillarATests {
    // MARK: - TestClock

    @Test
    func `now advances only when told`() {
        let clock = TestClock()
        #expect(clock.now == TestClock.Instant())
        clock.advance(by: .seconds(5))
        #expect(clock.now == TestClock.Instant(offset: .seconds(5)))
    }

    @Test
    func `a sleeper wakes exactly when time is advanced past its deadline`() async throws {
        let clock = TestClock()
        let woke = AsyncEventProbe<Int>()
        let sleeper = Task {
            try await clock.sleep(until: clock.now.advanced(by: .seconds(10)))
            woke.record(1)
        }
        // sleeperCount lets us sequence without a yield-guess: wait for it to park.
        while clock.sleeperCount == 0 { await Task.yield() }
        #expect(clock.sleeperCount == 1)
        #expect(woke.count == 0)

        clock.advance(by: .seconds(9))  // not yet past the deadline
        #expect(woke.count == 0)
        clock.advance(by: .seconds(1))  // now at the deadline
        try await sleeper.value
        #expect(woke.events == [1])
        #expect(clock.sleeperCount == 0)
    }

    @Test
    func `a deadline already in the past returns without parking`() async throws {
        let clock = TestClock()
        clock.advance(by: .seconds(100))
        try await clock.sleep(until: clock.now.advanced(by: .seconds(-1)))
        #expect(clock.sleeperCount == 0)
    }

    // MARK: - AsyncEventProbe

    @Test
    func `wait returns the recorded events once the threshold is met`() async throws {
        let probe = AsyncEventProbe<Int>()
        let recorder = Task {
            for i in 1 ... 3 { probe.record(i) }
        }
        let events = try await probe.wait(forAtLeast: 3)
        #expect(events.count >= 3)
        await recorder.value
        #expect(probe.events == [1, 2, 3])
    }

    @Test
    func `wait times out deterministically under a TestClock with zero real time`() async throws {
        let clock = TestClock()
        let probe = AsyncEventProbe<Int>()
        // Advance only after the timeout sleeper has registered on the clock.
        let advancer = Task {
            while clock.sleeperCount == 0 { await Task.yield() }
            clock.advance(by: .seconds(5))
        }
        await #expect(throws: AsyncEventProbeTimeoutError.self) {
            try await probe.wait(forAtLeast: 1, within: .seconds(5), clock: clock)
        }
        await advancer.value
    }

    // MARK: - TaskProviderSpy

    @Test
    func `settles a batch of work tasks`() async throws {
        let spy = TaskProviderSpy()
        let probe = AsyncEventProbe<Int>()
        for i in 0 ..< 5 {
            spy.task { probe.record(i) }
        }
        #expect(spy.spawnedCount == 5)
        try await spy.waitForAllTasks()
        #expect(spy.completedCount == 5)
        #expect(spy.liveCount == 0)
        #expect(probe.count == 5)
    }

    @Test
    func `settles tasks spawned by other tasks transitively`() async throws {
        let spy = TaskProviderSpy()
        let probe = AsyncEventProbe<Int>()
        spy.task {
            probe.record(1)
            spy.task { probe.record(2) }
        }
        try await spy.waitForAllTasks()
        #expect(spy.spawnedCount == 2)
        #expect(spy.completedCount == 2)
        #expect(probe.count == 2)
    }

    @Test
    func `observation tasks are excluded from settling`() async throws {
        let spy = TaskProviderSpy()
        let started = AsyncEventProbe<Int>()
        let handle = spy.task(role: .observation) {
            started.record(1)
            try? await Task.sleep(for: .seconds(86_400))
        }
        _ = try await started.wait(forAtLeast: 1)
        // No `.work` tasks tracked, so settling returns at once despite the live loop.
        try await spy.waitForAllTasks()
        #expect(spy.spawnedCount == 0)
        handle.cancel()
    }

    @Test
    func `a hung work task makes settling time out under a TestClock`() async throws {
        let clock = TestClock()
        let spy = TaskProviderSpy()
        let hanging = spy.task {
            try? await Task.sleep(for: .seconds(86_400))  // never completes during the test
        }
        let advancer = Task {
            while clock.sleeperCount == 0 { await Task.yield() }
            clock.advance(by: .seconds(5))
        }
        await #expect(throws: AsyncEventProbeTimeoutError.self) {
            try await spy.waitForAllTasks(within: .seconds(5), clock: clock)
        }
        await advancer.value
        hanging.cancel()
    }

    // MARK: - TestClock advance(to:) / runToLastSleeper / cancellation

    @Test
    func `advance(to:) wakes a sleeper and is a no-op once already past it`() async throws {
        let clock = TestClock()
        let woke = AsyncEventProbe<Int>()
        let sleeper = Task {
            try await clock.sleep(until: TestClock.Instant(offset: .seconds(10)))
            woke.record(1)
        }
        while clock.sleeperCount == 0 { await Task.yield() }
        clock.advance(to: TestClock.Instant(offset: .seconds(10)))
        try await sleeper.value
        #expect(woke.events == [1])

        let before = clock.now
        clock.advance(to: TestClock.Instant(offset: .seconds(5)))  // already past → no-op
        #expect(clock.now == before)
    }

    @Test
    func `runToLastSleeper drains every parked sleeper`() async throws {
        let clock = TestClock()
        let woke = AsyncEventProbe<Int>()
        for seconds in [5, 20, 100] {
            Task {
                try? await clock.sleep(until: TestClock.Instant(offset: .seconds(seconds)))
                woke.record(seconds)
            }
        }
        while clock.sleeperCount < 3 { await Task.yield() }
        clock.runToLastSleeper()
        _ = try await woke.wait(forAtLeast: 3)
        #expect(Set(woke.events) == [5, 20, 100])
        #expect(clock.sleeperCount == 0)
    }

    @Test
    func `a cancelled sleeper throws CancellationError and unregisters`() async throws {
        let clock = TestClock()
        let parked = AsyncEventProbe<Int>()
        let sleeper = Task {
            parked.record(1)
            try await clock.sleep(until: TestClock.Instant(offset: .seconds(1000)))
        }
        _ = try await parked.wait(forAtLeast: 1)
        while clock.sleeperCount == 0 { await Task.yield() }
        sleeper.cancel()
        await #expect(throws: CancellationError.self) { try await sleeper.value }
        while clock.sleeperCount != 0 { await Task.yield() }
        #expect(clock.sleeperCount == 0)
    }

    @Test
    func `a cancelled probe.wait resumes with CancellationError`() async {
        let probe = AsyncEventProbe<Int>()
        let waiter = Task { try await probe.wait(forAtLeast: 5, timeout: .seconds(60)) }
        await Task.yield()
        waiter.cancel()
        await #expect(throws: CancellationError.self) { _ = try await waiter.value }
    }
}

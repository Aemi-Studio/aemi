import Synchronization
import Testing

@testable import AemiTestKit

/// `AsyncEventProbe`: recording, waiting for a count, the clock-injectable timeout and cancellation.
@Suite(.tags(.concurrency), .timeLimit(.minutes(1)))
struct AsyncEventProbeTests {
    /// Emits each value from its own unstructured task, so the test sees the events exactly as it would
    /// from a real system under test: as a side effect of background work.
    private struct NumberStreamer {
        let onEmit: @Sendable (Int) -> Void

        func start(emitting values: [Int]) {
            Task {
                for value in values {
                    await Task.yield()
                    onEmit(value)
                }
            }
        }
    }

    @Test
    func `wait awaits a producer that records from its own task`() async throws {
        let probe = AsyncEventProbe<Int>()
        let producer = NumberStreamer(onEmit: { probe.record($0) })

        producer.start(emitting: [1, 2, 3])
        let events = try await probe.wait(forAtLeast: 3)

        #expect(events == [1, 2, 3])
        #expect(probe.events == [1, 2, 3])
    }

    @Test
    func `record keeps the events in order`() {
        let probe = AsyncEventProbe<String>()
        #expect(probe.count == 0)
        #expect(probe.events.isEmpty)

        probe.record("a")
        probe.record("b")
        probe.record("c")

        #expect(probe.events == ["a", "b", "c"])
        #expect(probe.count == 3)
    }

    @Test
    func `wait returns at once when the target is already met`() async throws {
        let probe = AsyncEventProbe<Int>()
        probe.record(1)
        probe.record(2)

        #expect(try await probe.wait(forAtLeast: 2) == [1, 2])
        #expect(try await probe.wait(forAtLeast: 1) == [1, 2])
        #expect(try await probe.wait(forAtLeast: 0) == [1, 2])
    }

    @Test
    func `wait returns the events as they were when the target was reached`() async throws {
        let probe = AsyncEventProbe<Int>()
        let waiter = Task { try await probe.wait(forAtLeast: 2) }
        await Self.letWaitersPark()

        probe.record(10)
        probe.record(20)
        probe.record(30)

        let events = try await waiter.value
        #expect(events.starts(with: [10, 20]))
        #expect(probe.events == [10, 20, 30])
    }

    @Test
    func `one record wakes every waiter whose threshold it crosses`() async throws {
        let probe = AsyncEventProbe<Int>()
        let waiters = (1 ... 3).map { target in Task { try await probe.wait(forAtLeast: target) } }
        await Self.letWaitersPark()

        probe.record(1)
        probe.record(2)
        probe.record(3)

        for (index, waiter) in waiters.enumerated() {
            #expect(try await waiter.value.count >= index + 1)
        }
    }

    @Test
    func `a wait under a test clock times out only when the clock is advanced`() async throws {
        let clock = TestClock()
        let probe = AsyncEventProbe<String>()
        probe.record("partial")
        let waiter = Task { try await probe.wait(forAtLeast: 3, within: .seconds(30), clock: clock) }
        try await clock.waitForSleepers(atLeast: 1)

        for _ in 0 ..< 50 { await Task.yield() }
        clock.advance(by: .seconds(29))
        for _ in 0 ..< 50 { await Task.yield() }
        clock.advance(by: .seconds(1))

        let error = await #expect(throws: AsyncEventProbeTimeoutError.self) { try await waiter.value }
        #expect(error?.requested == 3)
        #expect(error?.recorded == 1)
    }

    @Test
    func `a wait that reaches its target under a test clock never needs the clock`() async throws {
        let clock = TestClock()
        let probe = AsyncEventProbe<Int>()
        let waiter = Task { try await probe.wait(forAtLeast: 1, within: .seconds(30), clock: clock) }
        try await clock.waitForSleepers(atLeast: 1)

        probe.record(7)

        #expect(try await waiter.value == [7])
    }

    @Test
    func `cancelling the awaiting task throws CancellationError`() async throws {
        let probe = AsyncEventProbe<Int>()
        let waiter = Task { try await probe.wait(forAtLeast: 1, timeout: .seconds(30)) }
        await Self.letWaitersPark()

        waiter.cancel()

        await #expect(throws: CancellationError.self) { try await waiter.value }
    }

    /// Lets waiter tasks reach their first suspension. The probe exposes no waiter count, so the test yields
    /// until they have had time to park; a wait that has not parked yet still completes correctly because
    /// the probe checks the count under its lock.
    private static func letWaitersPark() async {
        for _ in 0 ..< 100 { await Task.yield() }
    }
}

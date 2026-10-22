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
        await Self.waitUntilParked(1, on: probe)

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
        await Self.waitUntilParked(3, on: probe)

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
        try await clock.waitForUntrackedSleepers(atLeast: 1)

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
        try await clock.waitForUntrackedSleepers(atLeast: 1)

        probe.record(7)

        #expect(try await waiter.value == [7])
    }

    @Test
    func `cancelling the awaiting task throws CancellationError`() async throws {
        let probe = AsyncEventProbe<Int>()
        let waiter = Task { try await probe.wait(forAtLeast: 1, timeout: .seconds(30)) }
        await Self.waitUntilParked(1, on: probe)

        waiter.cancel()

        await #expect(throws: CancellationError.self) { try await waiter.value }
    }

    /// Every record wakes a waiter. If the wake handed the waiter a snapshot of the events, the producer's next
    /// append would find the buffer shared and copy it, once per record: 3000 reallocations for 3000 records.
    /// Appending to an unshared buffer reallocates only when it grows, a handful of times.
    @Test
    func `waking a waiter does not make the next record copy the events`() async throws {
        let count = 3000
        let probe = AsyncEventProbe<Int>()
        let waiters = (1 ... count).map { target in Task { try await probe.wait(forAtLeast: target) } }
        await Self.waitUntilParked(count, on: probe)

        var reallocations = 0
        var previous: UInt = 0
        for event in 0 ..< count {
            probe.record(event)
            let address = probe.events.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) }
            if address != previous { reallocations += 1 }
            previous = address
        }

        for (index, waiter) in waiters.enumerated() {
            #expect(try await waiter.value.count >= index + 1)
        }
        #expect(reallocations < count / 4, "the event buffer was reallocated \(reallocations) times")
    }

    @Test
    func `a wait that parked returns exactly the events up to its threshold`() async throws {
        let probe = AsyncEventProbe<Int>()
        let waiter = Task { try await probe.wait(forAtLeast: 2) }
        await Self.waitUntilParked(1, on: probe)

        probe.record(1)
        probe.record(2)
        probe.record(3)

        #expect(try await waiter.value == [1, 2])
    }

    /// Yields until `count` waits are parked on the probe, so a record that follows cannot race a wait's registration.
    private static func waitUntilParked(_ count: Int, on probe: AsyncEventProbe<some Sendable>) async {
        while probe.waiterCount < count { await Task.yield() }
    }
}

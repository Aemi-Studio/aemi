import Testing

@testable import AemiTestKit

@Suite(.tags(.concurrency))
struct AsyncGateTests {
    @Test
    func `an initially-open gate lets the first waiter proceed without suspending`() async throws {
        let gate = AsyncGate(initiallyOpen: true)
        try await gate.waitUntilOpen()  // consumes the banked permit; never suspends
        #expect(gate.waiterCount == 0)
    }

    @Test
    func `open() before any waiter banks a permit the next wait consumes`() async throws {
        let gate = AsyncGate()
        gate.open()  // no waiter → permit banked
        try await gate.waitUntilOpen()
        #expect(gate.waiterCount == 0)
    }

    @Test
    func `waitUntilOpen suspends until open() is called`() async throws {
        let gate = AsyncGate()
        let passed = AsyncEventProbe<Int>()
        let holder = Task {
            try await gate.waitUntilOpen()
            passed.record(1)
        }
        while gate.waiterCount == 0 { await Task.yield() }
        #expect(passed.count == 0)  // parked, not yet released
        gate.open()
        _ = try await passed.wait(forAtLeast: 1)
        #expect(passed.events == [1])
        try await holder.value
    }

    @Test
    func `each open() releases exactly one holder`() async throws {
        let gate = AsyncGate()
        let released = AsyncEventProbe<Int>()
        let a = Task {
            try await gate.waitUntilOpen()
            released.record(1)
        }
        while gate.waiterCount < 1 { await Task.yield() }
        let b = Task {
            try await gate.waitUntilOpen()
            released.record(2)
        }
        while gate.waiterCount < 2 { await Task.yield() }

        gate.open()
        _ = try await released.wait(forAtLeast: 1)
        #expect(released.count == 1)  // only one freed; the other is still parked
        gate.open()
        _ = try await released.wait(forAtLeast: 2)
        #expect(Set(released.events) == [1, 2])
        try await a.value
        try await b.value
    }

    @Test
    func `a cancelled waiter throws CancellationError and unregisters`() async throws {
        let gate = AsyncGate()
        let parked = AsyncEventProbe<Int>()
        let holder = Task {
            parked.record(1)
            try await gate.waitUntilOpen()
        }
        _ = try await parked.wait(forAtLeast: 1)
        while gate.waiterCount == 0 { await Task.yield() }
        holder.cancel()
        await #expect(throws: CancellationError.self) { try await holder.value }
        while gate.waiterCount != 0 { await Task.yield() }
        #expect(gate.waiterCount == 0)
    }

    @Test
    func `withAsyncGatedBatch resumes the holder only after the gate opens`() async {
        let order = AsyncEventProbe<String>()
        await withAsyncGatedBatch(
            hold: { gate in
                order.record("holder-start")
                try? await gate.waitUntilOpen()
                order.record("holder-resumed")
            },
            { openGate in
                order.record("body")
                openGate()
            })
        #expect(order.count == 3)
        #expect(order.events.last == "holder-resumed")
        #expect(order.events.contains("body"))
    }
}

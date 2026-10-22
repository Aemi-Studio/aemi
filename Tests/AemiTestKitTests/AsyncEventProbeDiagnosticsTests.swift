import Synchronization
import Testing

@testable import AemiTestKit

/// `AsyncEventProbe`'s family contract: count-only probes, labels and creation sites, the bounded timeout
/// message, condition waits and the cancellation rules. Timeouts run on a `TestClock`, so none of them costs time.
@Suite(.tags(.concurrency), .timeLimit(.minutes(1)))
struct AsyncEventProbeDiagnosticsTests {
    /// Waits on `probe` under a test clock, advances past the timeout once it is armed, and returns the error.
    private func timeout<Event: Sendable>(
        of probe: AsyncEventProbe<Event>, waiting body: @escaping @Sendable (TestClock) async throws -> Void
    ) async throws -> AsyncEventProbeTimeoutError {
        let clock = TestClock()
        let waiter = Task { try await body(clock) }
        try await clock.waitForUntrackedSleepers(atLeast: 1)
        clock.advance(by: .seconds(60))
        do {
            try await waiter.value
        } catch let error as AsyncEventProbeTimeoutError {
            return error
        }
        Issue.record("the wait did not time out")
        throw CancellationError()
    }

    // MARK: Count-only

    @Test
    func `a probe with no payload type counts without storing events`() async throws {
        let probe = AsyncEventProbe()  // resolves to AsyncEventProbe<Never>
        #expect(probe.isEmpty)
        let waiter = Task { try await probe.wait(forAtLeast: 2) }
        while probe.waiterCount < 1 { await Task.yield() }

        probe.record()
        probe.record()

        let events = try await waiter.value
        #expect(events.isEmpty)
        #expect(probe.count == 2)
        #expect(!probe.isEmpty)
        #expect(probe.events.isEmpty)
    }

    @Test
    func `a count-only wait that is already satisfied returns at once`() async throws {
        let probe = AsyncEventProbe<Never>()
        probe.record()
        try await probe.wait(forAtLeast: 1)
        try await probe.wait(forAtLeast: 0)
    }

    @Test
    func `a count-only timeout reports the count and lists no events`() async throws {
        let probe = AsyncEventProbe(label: "ticks")
        probe.record()
        let error = try await timeout(of: probe) { clock in
            try await probe.wait(forAtLeast: 3, within: .seconds(30), clock: clock)
        }
        #expect(error.requested == 3)
        #expect(error.recorded == 1)
        #expect(error.recentEvents.isEmpty)
        #expect(error.description.contains("'ticks'"))
        #expect(error.description.contains("at least 3 event(s); 1 recorded."))
    }

    // MARK: Label, creation and the bounded message

    @Test
    func `the timeout error carries the label, the counts and the creation site`() async throws {
        let line = #line + 1
        let probe = AsyncEventProbe<String>(label: "writes")
        probe.record("first")
        let error = try await timeout(of: probe) { clock in
            try await probe.wait(forAtLeast: 4, within: .seconds(30), clock: clock)
        }
        #expect(error.label == "writes")
        #expect(error.requested == 4)
        #expect(error.recorded == 1)
        #expect(!error.isPredicateWait)
        #expect(error.creation.line == line)
        #expect(error.creation.fileID.hasSuffix("AsyncEventProbeDiagnosticsTests.swift"))
        #expect(error.description.contains("AsyncEventProbe 'writes' timed out waiting for at least 4 event(s)"))
        #expect(error.description.contains(#"[#0 first]"#))
        #expect(error.description.contains("Probe created at"))
    }

    @Test
    func `an unlabelled probe is named by its type`() async throws {
        let probe = AsyncEventProbe<Int>()
        let error = try await timeout(of: probe) { clock in
            try await probe.wait(forAtLeast: 1, within: .seconds(30), clock: clock)
        }
        #expect(error.description.hasPrefix("AsyncEventProbe timed out waiting for at least 1 event(s)"))
        #expect(error.description.contains("nothing was recorded"))
    }

    @Test
    func `the message lists only the most recent events and cuts long ones`() async throws {
        let probe = AsyncEventProbe<String>(label: "log")
        for index in 0 ..< 25 { probe.record("line \(index) " + String(repeating: "x", count: 500)) }
        let error = try await timeout(of: probe) { clock in
            try await probe.wait(forAtLeast: 99, within: .seconds(30), clock: clock)
        }
        let limit = AsyncEventProbeTimeoutError.maximumListedEvents
        #expect(error.recentEvents.count == limit)
        #expect(error.omittedEvents == 25 - limit)
        #expect(error.recentEvents.allSatisfy { $0.count <= AsyncEventProbeTimeoutError.maximumEventDescriptionLength })
        #expect(error.recentEvents.last?.hasSuffix("…") == true)
        #expect(error.description.contains("#24 line 24"))
        #expect(error.description.contains("#15 line 15"))
        #expect(!error.description.contains("#14 "))
        #expect(error.description.contains("15 earlier event(s) omitted"))
        #expect(error.description.count < 2000, "the message stays bounded however many events were recorded")
    }

    // MARK: Conditions on the events

    @Test
    func `a condition that already holds returns every recorded event`() async throws {
        let probe = AsyncEventProbe<Int>()
        probe.record(1)
        probe.record(2)
        probe.record(3)

        #expect(try await probe.wait(until: { $0.contains(2) }) == [1, 2, 3])
    }

    @Test
    func `a condition wait returns the events as they were when it first held`() async throws {
        let probe = AsyncEventProbe<Int>()
        let waiter = Task { try await probe.wait(until: { $0.contains(3) }) }
        while probe.waiterCount < 1 { await Task.yield() }

        for event in 1 ... 6 { probe.record(event) }

        // Recorded straight through, but the waiter looks at each prefix in turn: it stops at the 3.
        #expect(try await waiter.value == [1, 2, 3])
    }

    @Test
    func `a condition is evaluated on the events so far and again after each record`() async throws {
        let probe = AsyncEventProbe<String>()
        let seen = Mutex<[Int]>([])
        let waiter = Task {
            try await probe.wait(until: { events in
                seen.withLock { $0.append(events.count) }
                return events.last == "done"
            })
        }
        while seen.withLock({ $0.count }) < 1 { await Task.yield() }
        for event in ["a", "b", "done"] {
            probe.record(event)
            while seen.withLock({ $0.last }) != probe.count { await Task.yield() }
        }
        #expect(try await waiter.value == ["a", "b", "done"])
        #expect(seen.withLock { $0 } == [0, 1, 2, 3])
    }

    @Test
    func `a condition may read the probe it waits on`() async throws {
        let probe = AsyncEventProbe<Int>()
        probe.record(1)
        let events = try await probe.wait(until: { _ in probe.count >= 1 })
        #expect(events == [1])
    }

    @Test
    func `a condition that never holds times out with a condition message`() async throws {
        let probe = AsyncEventProbe<String>(label: "states")
        probe.record("starting")
        let error = try await timeout(of: probe) { clock in
            try await probe.wait(until: { $0.contains("ready") }, within: .seconds(30), clock: clock)
        }
        #expect(error.isPredicateWait)
        #expect(error.recorded == 1)
        #expect(error.description.contains("waiting for the recorded events to satisfy a condition"))
        #expect(error.description.contains("[#0 starting]"))
    }

    // MARK: Cancellation

    @Test
    func `a wait in an already cancelled task throws even if its boundary was reached`() async {
        let probe = AsyncEventProbe<Int>()
        probe.record(1)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await probe.wait(forAtLeast: 1)
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }

        let cancelledCondition = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await probe.wait(until: { !$0.isEmpty })
        }
        await #expect(throws: CancellationError.self) { try await cancelledCondition.value }

        let cancelledZero = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await probe.wait(forAtLeast: 0)
        }
        await #expect(throws: CancellationError.self) { try await cancelledZero.value }
    }

    @Test
    func `cancelling a suspended wait throws CancellationError and unregisters it`() async throws {
        let probe = AsyncEventProbe<Int>()
        let byCount = Task { try await probe.wait(forAtLeast: 5, timeout: .seconds(30)) }
        let byCondition = Task { try await probe.wait(until: { $0.count >= 5 }, timeout: .seconds(30)) }
        while probe.waiterCount < 2 { await Task.yield() }

        byCount.cancel()
        byCondition.cancel()

        await #expect(throws: CancellationError.self) { try await byCount.value }
        await #expect(throws: CancellationError.self) { try await byCondition.value }
        while probe.waiterCount > 0 { await Task.yield() }
        #expect(probe.waiterCount == 0)
    }

    @Test
    func `a wait cancelled while armed on a test clock leaves no timeout parked`() async throws {
        let clock = TestClock()
        let probe = AsyncEventProbe<Int>()
        let waiter = Task { try await probe.wait(forAtLeast: 1, within: .seconds(30), clock: clock) }
        try await clock.waitForUntrackedSleepers(atLeast: 1)

        waiter.cancel()

        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(clock.untrackedSleeperCount == 0)
        #expect(clock.sleeperCount == 0)
    }
}

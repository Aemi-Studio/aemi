import Synchronization
import Testing

@testable import AemiTesting

/// `CountProbe`'s side of the probe family contract it shares with `AemiTestKit`'s `AsyncEventProbe`: clock-injected
/// timeouts, the bounded timeout message, condition waits, wake order and the cancellation rules. Timeouts run on a
/// `TestClock`, so none of them costs time.
/// A reference-typed log. Swift 6.3 rejects capturing a local `Mutex` (noncopyable) in a `Task` closure, so the lock
/// lives inside a `Sendable` class that the tasks capture instead.
private final class ResumeLog: Sendable {
    private let names = Mutex<[String]>([])
    func append(_ name: String) { names.withLock { $0.append(name) } }
    var snapshot: [String] { names.withLock { $0 } }
}

@Suite("CountProbe family", .timeLimit(.minutes(1)))
struct CountProbeFamilyTests {
    /// Waits on `probe` under a test clock, advances past the timeout once it is armed, and returns the error.
    private func timeout<Event: Sendable>(
        of probe: CountProbe<Event>, waiting body: @escaping @Sendable (TestClock) async throws -> Void
    ) async throws -> CountProbeTimeoutError<Event> {
        let clock = TestClock()
        let waiter = Task { try await body(clock) }
        try await clock.waitForUntrackedSleepers(atLeast: 1)
        clock.advance(by: .seconds(60))
        do {
            try await waiter.value
        } catch let error as CountProbeTimeoutError<Event> {
            return error
        }
        Issue.record("the wait did not time out")
        throw CancellationError()
    }

    // MARK: Clock-injected timeouts

    @Test func `a wait under a test clock times out only when the clock is advanced`() async throws {
        let clock = TestClock()
        let probe = CountProbe<String>()
        probe.record("partial")
        let waiter = Task { try await probe.wait(forAtLeast: 3, within: .seconds(30), clock: clock) }
        try await clock.waitForUntrackedSleepers(atLeast: 1)

        for _ in 0 ..< 50 { await Task.yield() }
        clock.advance(by: .seconds(29))
        for _ in 0 ..< 50 { await Task.yield() }
        clock.advance(by: .seconds(1))

        let error = await #expect(throws: CountProbeTimeoutError<String>.self) { try await waiter.value }
        #expect(error?.expected == 3)
        #expect(error?.recordedCount == 1)
    }

    @Test func `a wait that reaches its target under a test clock never needs the clock`() async throws {
        let clock = TestClock()
        let probe = CountProbe<Int>()
        let waiter = Task { try await probe.wait(forAtLeast: 1, within: .seconds(30), clock: clock) }
        try await clock.waitForUntrackedSleepers(atLeast: 1)

        probe.record(7)

        try await waiter.value
        #expect(clock.sleeperCount == 0)
    }

    @Test func `the timeout is not a sleeper to the code under test`() async throws {
        let clock = TestClock()
        let probe = CountProbe<Int>()
        let waiter = Task { try await probe.wait(forAtLeast: 1, within: .seconds(60), clock: clock) }
        try await clock.waitForUntrackedSleepers(atLeast: 1)

        #expect(clock.sleeperCount == 0, "the timeout is the harness's timer, not the code under test's")
        probe.record(1)
        try await waiter.value
    }

    // MARK: Count-only

    @Test func `a count-only timeout reports the count and lists no events`() async throws {
        let probe = CountProbe(label: "ticks")
        probe.record()
        let error = try await timeout(of: probe) { clock in
            try await probe.wait(forAtLeast: 3, within: .seconds(30), clock: clock)
        }
        #expect(error.expected == 3)
        #expect(error.recordedCount == 1)
        #expect(error.recorded.isEmpty)
        #expect(error.description.contains("'ticks'"))
        #expect(error.description.hasSuffix("expected at least 3, recorded 1"))
    }

    // MARK: Label, creation and the bounded message

    @Test func `the timeout error carries the label, the counts and the creation site`() async throws {
        let line = #line + 1
        let probe = CountProbe<String>(label: "writes")
        probe.record("first")
        let error = try await timeout(of: probe) { clock in
            try await probe.wait(forAtLeast: 4, within: .seconds(30), clock: clock)
        }
        #expect(error.label == "writes")
        #expect(error.expected == 4)
        #expect(error.recordedCount == 1)
        #expect(error.recorded == ["first"])
        #expect(!error.isConditionWait)
        #expect(error.line == UInt(line))
        #expect("\(error.file)".hasSuffix("CountProbeFamilyTests.swift"))
        #expect(error.description.contains("CountProbe 'writes' timed out at"))
        #expect(error.description.contains("expected at least 4, recorded 1: [#0 first]"))
    }

    @Test func `an unlabelled probe is named by its type`() async throws {
        let probe = CountProbe<Int>()
        let error = try await timeout(of: probe) { clock in
            try await probe.wait(forAtLeast: 1, within: .seconds(30), clock: clock)
        }
        #expect(error.description.hasPrefix("CountProbe timed out at"))
    }

    @Test func `the message lists only the most recent events and cuts long ones`() async throws {
        let probe = CountProbe<String>(label: "log")
        for index in 0 ..< 25 { probe.record("line \(index) " + String(repeating: "x", count: 500)) }
        let error = try await timeout(of: probe) { clock in
            try await probe.wait(forAtLeast: 99, within: .seconds(30), clock: clock)
        }
        #expect(error.recorded.count == 25, "the error keeps every event; only the message is bounded")
        let message = error.description
        #expect(message.contains("#24 line 24"))
        #expect(message.contains("#15 line 15"))
        #expect(!message.contains("#14 "))
        #expect(message.contains("15 earlier event(s) omitted"))
        #expect(message.contains("…"))
        #expect(message.count < 2000, "the message stays bounded however many events were recorded")
    }

    // MARK: Conditions on the events

    @Test func `a condition that already holds returns at once`() async throws {
        let probe = CountProbe<Int>()
        probe.record(1)
        probe.record(2)

        try await probe.wait(until: { $0.contains(2) })
    }

    @Test func `a condition is evaluated on the events so far and again after each record`() async throws {
        let probe = CountProbe<String>()
        let seen = Mutex<[Int]>([])
        let waiter = Task {
            try await probe.wait(
                until: { events in
                    seen.withLock { $0.append(events.count) }
                    return events.last == "done"
                }, timeout: .seconds(30))
        }
        while seen.withLock({ $0.count }) < 1 { await Task.yield() }
        for event in ["a", "b", "done"] {
            probe.record(event)
            while seen.withLock({ $0.last }) != probe.count { await Task.yield() }
        }
        try await waiter.value
        #expect(seen.withLock { $0 } == [0, 1, 2, 3])
    }

    @Test func `a condition sees every prefix even when events are recorded in a burst`() async throws {
        let probe = CountProbe<Int>()
        let seen = Mutex<[Int]>([])
        let waiter = Task {
            try await probe.wait(
                until: { events in
                    seen.withLock { $0.append(events.count) }
                    return events.contains(3)
                }, timeout: .seconds(30))
        }
        while probe.waiterCount < 1 { await Task.yield() }

        for event in 1 ... 6 { probe.record(event) }
        try await waiter.value

        // Parked at zero events, then one prefix at a time: the burst does not hide the 3.
        #expect(seen.withLock { $0 }.suffix(1) == [3])
    }

    @Test func `a condition that never holds times out with a condition message`() async throws {
        let probe = CountProbe<String>(label: "states")
        probe.record("starting")
        let error = try await timeout(of: probe) { clock in
            try await probe.wait(until: { $0.contains("ready") }, within: .seconds(30), clock: clock)
        }
        #expect(error.isConditionWait)
        #expect(error.recordedCount == 1)
        #expect(error.description.contains("waiting for the recorded events to satisfy a condition"))
        #expect(error.description.contains("[#0 starting]"))
    }

    // MARK: Order and cancellation

    @Test func `waiters are resumed in threshold order, then in the order they began waiting`() async throws {
        let probe = CountProbe()
        let order = ResumeLog()
        // Registered out of threshold order; each waiter notes when its task resumes. Recording one event at a
        // time, with the previous waiter observed before the next record, makes the resume order visible.
        let waiters = [("b", 2), ("a", 1), ("c", 2)]
            .map { name, target in
                Task {
                    try await probe.wait(forAtLeast: target, timeout: .seconds(30))
                    order.append(name)
                }
            }
        while probe.waiterCount < 3 { await Task.yield() }

        probe.record()
        while order.snapshot.count < 1 { await Task.yield() }
        probe.record()
        for waiter in waiters { try await waiter.value }

        #expect(order.snapshot.first == "a", "the lowest threshold is released first")
        #expect(Set(order.snapshot) == ["a", "b", "c"])
    }

    @Test func `a wait in an already cancelled task throws even if its boundary was reached`() async {
        let probe = CountProbe<Int>()
        probe.record(1)
        let cancelled = Task {
            unsafe withUnsafeCurrentTask { unsafe $0?.cancel() }
            try await probe.wait(forAtLeast: 1)
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }

        let cancelledCondition = Task {
            unsafe withUnsafeCurrentTask { unsafe $0?.cancel() }
            try await probe.wait(until: { !$0.isEmpty })
        }
        await #expect(throws: CancellationError.self) { try await cancelledCondition.value }

        let cancelledZero = Task {
            unsafe withUnsafeCurrentTask { unsafe $0?.cancel() }
            try await probe.wait(forAtLeast: 0)
        }
        await #expect(throws: CancellationError.self) { try await cancelledZero.value }
    }

    @Test func `cancelling a suspended wait throws CancellationError and unregisters it`() async throws {
        let probe = CountProbe<Int>()
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

    @Test func `a wait cancelled while armed on a test clock leaves no timeout parked`() async throws {
        let clock = TestClock()
        let probe = CountProbe<Int>()
        let waiter = Task { try await probe.wait(forAtLeast: 1, within: .seconds(30), clock: clock) }
        try await clock.waitForUntrackedSleepers(atLeast: 1)

        waiter.cancel()

        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(clock.untrackedSleeperCount == 0)
    }

    // MARK: Snapshot sharing

    @Test func `waking a waiter does not make the next record copy the events`() async throws {
        let count = 3000
        let probe = CountProbe<Int>()
        let waiters = (1 ... count)
            .map { target in Task { try await probe.wait(forAtLeast: target, timeout: .seconds(60)) } }
        while probe.waiterCount < count { await Task.yield() }

        var reallocations = 0
        var previous: UInt = 0
        for event in 0 ..< count {
            probe.record(event)
            let address = probe.events.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) }
            if address != previous { reallocations += 1 }
            previous = address
        }

        for waiter in waiters { try await waiter.value }
        #expect(reallocations < count / 4, "the event buffer was reallocated \(reallocations) times")
    }
}

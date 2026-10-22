import AemiCore
import Testing

@testable import AemiTesting

/// `TaskProviderSpy`'s waits race an injectable clock, so a hung task or a silent observer fails on a `TestClock`
/// without waiting in real time, and the failure names the probe that was waited on.
@Suite("TaskProviderSpy deadlines", .timeLimit(.minutes(1)))
struct TaskProviderSpyClockTests {
    @Test func `a hung work task times out on a test clock, naming the completed probe`() async throws {
        let clock = TestClock()
        let spy = TaskProviderSpy(label: "spy-under-test")
        let gate = TaskGate()
        spy.task { try? await gate.wait() }

        let waiter = Task { try await spy.waitForAllTasks(within: .seconds(5), clock: clock) }
        try await clock.waitForUntrackedSleepers(atLeast: 1)
        #expect(clock.sleeperCount == 0, "the deadline is the harness's timer, not the code under test's")
        clock.advance(by: .seconds(5))

        let error = await #expect(throws: CountProbeTimeoutError<Never>.self) { try await waiter.value }
        #expect(error?.label == "spy-under-test.completed")
        #expect(error?.expected == 1)
        gate.open()
        try await spy.waitForAllTasks()
    }

    @Test func `a silent observer times out on a test clock, naming the observations probe`() async throws {
        let clock = TestClock()
        let spy = TaskProviderSpy(label: "watchers")
        let gate = TaskGate()
        spy.task(role: .observation) { try? await gate.wait() }

        let waiter = Task { try await spy.waitForObservationsToFinish(within: .seconds(5), clock: clock) }
        try await clock.waitForUntrackedSleepers(atLeast: 1)
        clock.advance(by: .seconds(5))

        let error = await #expect(throws: CountProbeTimeoutError<Never>.self) { try await waiter.value }
        #expect(error?.label == "watchers.observationsFinished")
        gate.open()
        try await spy.waitForObservationsToFinish()
    }

    @Test func `waiting for a spawn times out on a test clock when nothing spawns`() async throws {
        let clock = TestClock()
        let spy = TaskProviderSpy(label: "idle")
        let waiter = Task { try await spy.waitForSpawnedTasks(atLeast: 1, within: .seconds(5), clock: clock) }
        try await clock.waitForUntrackedSleepers(atLeast: 1)
        clock.advance(by: .seconds(5))

        let error = await #expect(throws: CountProbeTimeoutError<Never>.self) { try await waiter.value }
        #expect(error?.label == "idle.spawned")
    }

    @Test func `settling on a test clock returns without touching the clock when the work finishes`() async throws {
        let clock = TestClock()
        let spy = TaskProviderSpy()
        let gate = TaskGate()
        spy.task { try? await gate.wait() }
        let waiter = Task { try await spy.waitForAllTasks(within: .seconds(5), clock: clock) }
        try await clock.waitForUntrackedSleepers(atLeast: 1)

        gate.open()

        try await waiter.value
        #expect(clock.now.offset == .zero)
        #expect(clock.untrackedSleeperCount == 0)
    }

    @Test func `the default timeout is 30 seconds, a hang guard`() {
        #expect(TaskProviderSpy().defaultTimeout == .seconds(30))
    }

    @Test func `the default timeout is public and applies to a wait given none`() async throws {
        let spy = TaskProviderSpy(defaultTimeout: .milliseconds(40))
        #expect(spy.defaultTimeout == .milliseconds(40))
        let gate = TaskGate()
        spy.task { try? await gate.wait() }

        await #expect(throws: CountProbeTimeoutError<Never>.self) { try await spy.waitForAllTasks() }

        gate.open()
        try await spy.waitForAllTasks()
    }
}

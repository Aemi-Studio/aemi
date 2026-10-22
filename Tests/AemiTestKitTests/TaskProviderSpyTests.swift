import AemiTestKitSeams
import Synchronization
import Testing

@testable import AemiTestKit

/// `TaskProviderSpy` bookkeeping: counting, transitive settling, observations, teardown and the injectable deadline.
@Suite(.tags(.concurrency), .timeLimit(.minutes(1)))
struct TaskProviderSpyTests {
    // MARK: Work

    @Test
    func `the returned handle is the real task and its result is delivered`() async throws {
        let spy = TaskProviderSpy()
        let plain = spy.task { 40 + 2 }
        let throwing = spy.task { () async throws -> String in "ok" }

        #expect(await plain.value == 42)
        #expect(try await throwing.value == "ok")
        try await spy.waitForAllTasks()
        #expect(spy.spawnedCount == 2)
        #expect(spy.completedCount == 2)
        #expect(spy.liveCount == 0)
    }

    @Test
    func `a throwing task that fails still counts as completed`() async throws {
        struct Failure: Error {}
        let spy = TaskProviderSpy()
        let task = spy.task { () async throws -> Int in throw Failure() }

        try await spy.waitForAllTasks()

        await #expect(throws: Failure.self) { try await task.value }
        #expect(spy.completedCount == 1)
    }

    @Test
    func `waitForAllTasks returns at once when nothing was spawned`() async throws {
        let spy = TaskProviderSpy()
        try await spy.waitForAllTasks()
        try await spy.waitForAllTasks(within: .seconds(1), clock: TestClock())
        #expect(spy.spawnedCount == 0)
    }

    @Test
    func `waitForAllTasks suspends until a spawned task finishes`() async throws {
        let spy = TaskProviderSpy()
        let gate = AsyncGate()
        spy.task { try? await gate.waitUntilOpen() }
        while gate.waiterCount < 1 { await Task.yield() }
        #expect(spy.liveCount == 1)

        gate.open()
        try await spy.waitForAllTasks()

        #expect(spy.completedCount == 1)
        #expect(spy.liveCount == 0)
    }

    @Test
    func `waitForAllTasks follows tasks spawned by tasks`() async throws {
        let spy = TaskProviderSpy()
        let gate = AsyncGate()
        spy.task {
            spy.task { try? await gate.waitUntilOpen() }
        }
        gate.open()

        try await spy.waitForAllTasks()

        #expect(spy.spawnedCount == 2)
        #expect(spy.completedCount == 2)
    }

    @Test
    func `many short tasks leave no handle behind`() async throws {
        let spy = TaskProviderSpy()
        for _ in 0 ..< 500 { spy.task {} }

        try await spy.waitForAllTasks()

        #expect(spy.trackedWorkHandleCount == 0, "a task that finished before it was attached must not be kept")
        #expect(spy.liveCount == 0)
    }

    // MARK: Deadlines

    @Test
    func `a hung task makes waitForAllTasks time out, naming the completed probe`() async throws {
        let clock = TestClock()
        let spy = TaskProviderSpy(label: "spy-under-test")
        let gate = AsyncGate()
        spy.task { try? await gate.waitUntilOpen() }

        let waiter = Task { try await spy.waitForAllTasks(within: .seconds(5), clock: clock) }
        try await clock.waitForUntrackedSleepers(atLeast: 1)
        clock.advance(by: .seconds(5))

        let error = await #expect(throws: AsyncEventProbeTimeoutError.self) { try await waiter.value }
        #expect(error?.label == "spy-under-test.completed")
        #expect(error?.requested == 1)
        #expect(error?.recorded == 0)
        gate.open()
        try await spy.waitForAllTasks()
    }

    @Test
    func `a chain that keeps respawning past the deadline times out instead of extending the wait`() async throws {
        let spy = TaskProviderSpy()
        let respawner = Respawner(spy: spy)
        respawner.respawn()

        await #expect(throws: AsyncEventProbeTimeoutError.self) {
            try await spy.waitForAllTasks(timeout: .milliseconds(50))
        }

        respawner.stop()
        try await spy.waitForAllTasks()
    }

    @Test
    func `the default timeout applies when a wait is given none`() async throws {
        let spy = TaskProviderSpy(defaultTimeout: .milliseconds(30))
        let gate = AsyncGate()
        spy.task { try? await gate.waitUntilOpen() }

        await #expect(throws: AsyncEventProbeTimeoutError.self) { try await spy.waitForAllTasks() }

        gate.open()
        try await spy.waitForAllTasks()
    }

    // MARK: Spawn boundary

    @Test
    func `waitForSpawnedTasks suspends until a task is spawned`() async throws {
        let spy = TaskProviderSpy()
        let boundary = Task { try await spy.waitForSpawnedTasks(atLeast: 1) }
        while spy.spawnWaiterCount < 1 { await Task.yield() }

        spy.task {}

        try await boundary.value
        try await spy.waitForAllTasks()
    }

    @Test
    func `waitForSpawnedTasks times out under a test clock when nothing spawns`() async throws {
        let clock = TestClock()
        let spy = TaskProviderSpy(label: "idle")
        let waiter = Task { try await spy.waitForSpawnedTasks(atLeast: 1, within: .seconds(5), clock: clock) }
        try await clock.waitForUntrackedSleepers(atLeast: 1)
        clock.advance(by: .seconds(5))

        let error = await #expect(throws: AsyncEventProbeTimeoutError.self) { try await waiter.value }
        #expect(error?.label == "idle.spawned")
    }

    // MARK: Observations

    @Test
    func `waitForAllTasks ignores observations`() async throws {
        let spy = TaskProviderSpy()
        let gate = AsyncGate()
        let observer = spy.task(role: .observation) { try? await gate.waitUntilOpen() }

        try await spy.waitForAllTasks()

        #expect(spy.spawnedCount == 0)
        #expect(spy.observationCount == 1)
        #expect(!observer.isCancelled)
        gate.open()
        await observer.value
    }

    @Test
    func `waitForObservationsToFinish returns at once with no observers`() async throws {
        let spy = TaskProviderSpy()
        try await spy.waitForObservationsToFinish()
        #expect(spy.observationCount == 0)
    }

    @Test
    func `waitForObservationsToFinish suspends until the observer ends`() async throws {
        let spy = TaskProviderSpy()
        let gate = AsyncGate()
        spy.task(role: .observation) { try? await gate.waitUntilOpen() }
        while gate.waiterCount < 1 { await Task.yield() }

        gate.open()
        try await spy.waitForObservationsToFinish()

        #expect(spy.observationCount == 0)
    }

    @Test
    func `waitForObservationsToFinish times out naming the observations probe`() async throws {
        let clock = TestClock()
        let spy = TaskProviderSpy(label: "watchers")
        let gate = AsyncGate()
        spy.task(role: .observation) { try? await gate.waitUntilOpen() }

        let waiter = Task { try await spy.waitForObservationsToFinish(within: .seconds(5), clock: clock) }
        try await clock.waitForUntrackedSleepers(atLeast: 1)
        clock.advance(by: .seconds(5))

        let error = await #expect(throws: AsyncEventProbeTimeoutError.self) { try await waiter.value }
        #expect(error?.label == "watchers.observationsFinished")
        gate.open()
        try await spy.waitForObservationsToFinish()
    }

    // MARK: Teardown

    @Test
    func `cancelObservations cancels the observers`() async throws {
        let spy = TaskProviderSpy()
        let gate = AsyncGate()
        let observer = spy.task(role: .observation) { () async throws -> Void in try await gate.waitUntilOpen() }
        while gate.waiterCount < 1 { await Task.yield() }

        spy.cancelObservations()

        await #expect(throws: CancellationError.self) { try await observer.value }
        try await spy.waitForObservationsToFinish()
        #expect(spy.observationCount == 0)
    }

    @Test
    func `cancelPendingWork cancels running work, which then settles`() async throws {
        let spy = TaskProviderSpy()
        let gate = AsyncGate()
        let work = spy.task { () async throws -> Void in try await gate.waitUntilOpen() }
        while gate.waiterCount < 1 { await Task.yield() }

        spy.cancelPendingWork()

        await #expect(throws: CancellationError.self) { try await work.value }
        try await spy.waitForAllTasks()
        #expect(work.isCancelled)
        #expect(spy.completedCount == 1)
        #expect(spy.trackedWorkHandleCount == 0)
    }

    @Test
    func `cancelling work that already finished is harmless`() async throws {
        let spy = TaskProviderSpy()
        let done = spy.task { 1 }
        try await spy.waitForAllTasks()

        spy.cancelPendingWork()
        spy.cancelObservations()

        #expect(await done.value == 1)
        #expect(!done.isCancelled)
    }

    @Test
    func `dropping the spy cancels the work and observers it still tracks`() async throws {
        let gate = AsyncGate()
        let cancelled = AsyncEventProbe<String>()
        var spy: TaskProviderSpy? = TaskProviderSpy()
        spy?
            .task {
                do { try await gate.waitUntilOpen() } catch { cancelled.record("work") }
            }
        spy?
            .task(role: .observation) {
                do { try await gate.waitUntilOpen() } catch { cancelled.record("observation") }
            }
        while gate.waiterCount < 2 { await Task.yield() }

        spy = nil

        let events = try await cancelled.wait(forAtLeast: 2)
        #expect(Set(events) == ["work", "observation"])
    }
}

/// Spawns a task that spawns its own successor until stopped. A class (not a local function) because a recursive
/// `@Sendable` local function cannot cross the provider's `sending` boundary under region isolation.
private final class Respawner: Sendable {
    private let spy: TaskProviderSpy
    private let keepSpawning = Mutex(true)

    init(spy: TaskProviderSpy) { self.spy = spy }

    func respawn() {
        guard keepSpawning.withLock({ $0 }) else { return }
        spy.task { self.respawn() }
    }

    func stop() { keepSpawning.withLock { $0 = false } }
}

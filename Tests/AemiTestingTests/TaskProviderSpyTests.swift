import AemiCore
import Testing

@testable import AemiTesting

/// `TaskProviderSpy` bookkeeping coverage: spawn/completion counting, chain-following waits,
/// deterministic teardown, observation exclusion, and diagnostic timeouts.
@Suite("TaskProviderSpy")
struct TaskProviderSpyTests {

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)

    @Test func countsSpawnsAndCompletions() async throws {
        let spy = TaskProviderSpy()
        spy.task { }
        spy.task { }
        spy.task { }
        try await spy.waitForAllTasks()
        #expect(spy.spawnedTaskCount == 3)
        #expect(spy.completedTaskCount == 3)
        #expect(spy.pendingWorkTaskCount == 0)
    }

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)

    @Test func detachedWorkIsTrackedLikeAttachedWork() async throws {
        let spy = TaskProviderSpy()
        spy.detachedTask { }
        try await spy.waitForAllTasks()
        #expect(spy.spawnedTaskCount == 1)
        #expect(spy.completedTaskCount == 1)
        #expect(spy.pendingWorkTaskCount == 0)
    }

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)

    @Test func waitForAllTasksFollowsARespawnChain() async throws {
        let spy = TaskProviderSpy()
        spy.task {
            spy.task { }
        }
        try await spy.waitForAllTasks()
        #expect(spy.spawnedTaskCount == 2)
        #expect(spy.completedTaskCount == 2)
        #expect(spy.pendingWorkTaskCount == 0)
    }

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)

    @Test func cancelPendingWorkCancelsOutstandingWork() async throws {
        let spy = TaskProviderSpy()
        let gate = TaskGate()
        let blocked = spy.task {
            try await gate.wait()
        }
        spy.cancelPendingWork()
        await #expect(throws: CancellationError.self) {
            try await blocked.value
        }
        #expect(spy.pendingWorkTaskCount == 0)
        // The cancelled task still completes (with an error), so the spy's ledger balances.
        try await spy.waitForAllTasks()
        #expect(spy.completedTaskCount == 1)
    }

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)

    @Test func observationsAreExcludedFromWaitForAllTasks() async throws {
        let spy = TaskProviderSpy()
        let gate = TaskGate()
        spy.task(role: .observation, priority: nil) {
            try await gate.wait()
        }
        spy.detachedTask(role: .observation, priority: nil) {
            try await gate.wait()
        }
        // Neither observer can ever finish, yet the wait returns: observers are not counted.
        try await spy.waitForAllTasks(timeout: .milliseconds(100))
        #expect(spy.spawnedTaskCount == 0)
        #expect(spy.completedTaskCount == 0)
        #expect(spy.observationCount == 2)
        spy.cancelObservations()
        #expect(spy.observationCount == 0)
    }

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)

    @Test func waitForAllTasksTimeoutNamesTheCompletedProbe() async throws {
        let spy = TaskProviderSpy(label: "spy-under-test", defaultTimeout: .milliseconds(50))
        let gate = TaskGate()
        spy.task {
            try await gate.wait()
        }
        do {
            try await spy.waitForAllTasks()
            Issue.record("Expected waitForAllTasks to time out")
        } catch let error as CountProbeTimeoutError<Never> {
            #expect(error.label == "spy-under-test.completed")
            #expect(error.expected == 1)
            #expect(error.recordedCount == 0)
            #expect(error.description.contains("CountProbe 'spy-under-test.completed'"))
        }
        gate.open()
        try await spy.waitForAllTasks(timeout: .seconds(1))
        #expect(spy.completedTaskCount == 1)
    }

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)

    @Test func waitForObservationsToFinishReturnsImmediatelyWithNoObservers() async throws {
        let spy = TaskProviderSpy()
        try await spy.waitForObservationsToFinish()
        #expect(spy.observationCount == 0)
    }

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)

    @Test func waitForObservationsToFinishSuspendsUntilAnObserverEnds() async throws {
        let spy = TaskProviderSpy()
        let gate = TaskGate()
        let observer = spy.task(role: .observation, priority: nil) {
            try await gate.wait()
        }
        #expect(spy.observationCount == 1)

        gate.open()
        try await spy.waitForObservationsToFinish()

        #expect(!observer.isCancelled)
        // The finished observer is released before its completion is counted.
        #expect(spy.observationCount == 0)
    }

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)

    @Test func waitForObservationsToFinishTimeoutNamesTheObservationProbe() async throws {
        let spy = TaskProviderSpy(label: "spy-under-test")
        let gate = TaskGate()
        spy.task(role: .observation, priority: nil) {
            try await gate.wait()
        }
        do {
            try await spy.waitForObservationsToFinish(timeout: .milliseconds(50))
            Issue.record("Expected waitForObservationsToFinish to time out")
        } catch let error as CountProbeTimeoutError<Never> {
            #expect(error.label == "spy-under-test.observationsFinished")
            #expect(error.expected == 1)
            #expect(error.recordedCount == 0)
        }

        gate.open()
        try await spy.waitForObservationsToFinish()
        #expect(spy.observationCount == 0)
    }

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)

    @Test func waitForSpawnedTasksObservesASpawnFromAnotherTask() async throws {
        let spy = TaskProviderSpy()
        Task.detached {
            spy.task { }
        }
        try await spy.waitForSpawnedTasks(atLeast: 1)
        #expect(spy.spawnedTaskCount == 1)
        try await spy.waitForAllTasks()
    }
}

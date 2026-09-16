import Testing

@testable import AemiTesting

/// Semaphore permits, cancellation, and FIFO handoff after observed registration.
@Suite("AsyncSemaphore")
struct AsyncSemaphoreTests {
    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)

    @Test func waitReturnsImmediatelyWhenPermitAvailable() async throws {
        let sem = AsyncSemaphore(value: 1)
        try await sem.wait()  // consumes the pre-loaded permit
    }

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)

    @Test func waitSuspendsUntilSignal() async throws {
        let sem = AsyncSemaphore()
        let task = Task { try await sem.wait() }
        sem.signal()
        try await task.value
    }

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)

    @Test func signalIncrementsWhenNoWaiters() async throws {
        let sem = AsyncSemaphore()
        sem.signal()
        sem.signal()
        try await sem.wait()
        try await sem.wait()
    }

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)

    @Test func `signals resume waiters in registration order`() async throws {
        let sut = AsyncSemaphore()
        let queued = CountProbe()
        let resumed = CountProbe<Int>()
        let count = 4

        try await withThrowingTaskGroup(of: Void.self) { group in
            defer { group.cancelAll() }
            for index in 0 ..< count {
                group.addTask {
                    try await sut.wait(onEnqueue: { queued.record() })
                    resumed.record(index)
                }
                // Creation order alone does not establish semaphore registration order.
                try await queued.wait(forAtLeast: index + 1)
            }
            for index in 0 ..< count {
                sut.signal()
                try await resumed.wait(forAtLeast: index + 1)
                #expect(resumed.events == Array(0 ... index))
            }
            try await group.waitForAll()
        }
    }

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)

    @Test func cancellationDoesNotConsumePermit() async throws {
        let sem = AsyncSemaphore()
        let task = Task { try await sem.wait() }
        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        // The cancellation should not have consumed a permit.
        // Signal once and a fresh wait must succeed.
        sem.signal()
        try await sem.wait()
    }
}

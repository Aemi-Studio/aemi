import Testing

@testable import AemiTesting

/// `AsyncSemaphore` regression coverage. Uses `TaskGate` as the
/// oracle for FIFO ordering — one gate per parallel slot; the
/// order gates open in mirrors the order signal() resumes waiters.
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

    @Test func waitersResumeFIFO() async throws {
        // Oracle: one TaskGate per waiter, opened from inside the
        // resumed body. Order of opens = order of signal-resumes.
        let sem = AsyncSemaphore()
        let n = 4
        let order = OrderRecorder()
        let gates = (0..<n).map { _ in TaskGate() }

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<n {
                group.addTask {
                    try? await sem.wait()
                    await order.record(i)
                    gates[i].open()
                }
            }

            // Signal one at a time, waiting for each gate before
            // signalling the next. This forces strict serial
            // observation of resume order.
            for i in 0..<n {
                sem.signal()
                try? await gates[i].wait()
            }
        }

        let observed = await order.snapshot
        #expect(observed == Array(0..<n))
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

/// Trivial actor for ordering observations across concurrent tasks.
actor OrderRecorder {
    private(set) var snapshot: [Int] = []
    func record(_ index: Int) { snapshot.append(index) }
}

import Testing

@testable import AemiTesting

/// `TaskGate` regression coverage. Uses `AsyncSemaphore` as the
/// oracle for counting parallel waiter resumes — when the gate
/// opens, every waiter should be resumed exactly once and a
/// signal-per-resume counts them deterministically.
@Suite("TaskGate")
struct TaskGateTests {

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)

    @Test func waitReturnsImmediatelyWhenAlreadyOpen() async throws {
        let gate = TaskGate()
        gate.open()
        try await gate.wait()  // returns immediately, no suspension
    }

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)

    @Test func openResumesQueuedWaiter() async throws {
        let gate = TaskGate()
        let task = Task { try await gate.wait() }
        // No yield. The gate.open() below could fire before or
        // after `gate.wait` registers; the gate handles both —
        // either we find waiters and resume them, or we transition
        // to .open and subsequent waits return immediately.
        gate.open()
        try await task.value
    }

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)

    @Test func openIsIdempotent() async throws {
        let gate = TaskGate()
        gate.open()
        gate.open()
        gate.open()
        try await gate.wait()  // still works
    }

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)

    @Test func openResumesAllParallelWaiters() async throws {
        // Oracle: AsyncSemaphore counts resumes. After open(),
        // every parallel waiter signals exactly once.
        let gate = TaskGate()
        let counter = AsyncSemaphore()
        let n = 8

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<n {
                group.addTask {
                    try? await gate.wait()
                    counter.signal()
                }
            }
            // Open the gate from outside the group. Workers may
            // have registered or may still be racing to register;
            // both code paths converge on "every wait() resumes".
            gate.open()
        }

        // Drain the semaphore to confirm exactly `n` resumes.
        for _ in 0..<n {
            try await counter.wait()
        }
    }

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)

    @Test func cancellationThrowsCancellationError() async throws {
        let gate = TaskGate()
        let task = Task { try await gate.wait() }
        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }
}

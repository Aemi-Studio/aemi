import Testing

@testable import AemiTesting

/// `AsyncProbe` regression coverage. Uses `TaskGate` as the source
/// of "production has signalled" events to drive `send` and assert
/// `next` resumes deterministically.
@Suite("AsyncProbe")
struct AsyncProbeTests {

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)

    @Test func nextReturnsBufferedSend() async throws {
        let probe = AsyncProbe<Int>()
        probe.send(42)
        let received = try await probe.next()
        #expect(received == 42)
    }

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)

    @Test func nextSuspendsUntilSend() async throws {
        let probe = AsyncProbe<String>()
        let task = Task { try await probe.next() }
        probe.send("hello")
        let received = try await task.value
        #expect(received == "hello")
    }

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)

    @Test func nextReturnsNilAfterFinish() async throws {
        let probe = AsyncProbe<Int>()
        probe.finish()
        let received = try await probe.next()
        #expect(received == nil)
    }

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)

    @Test func finishResumesQueuedWaiters() async throws {
        let probe = AsyncProbe<Int>()
        let task = Task { try await probe.next() }
        probe.finish()
        let received = try await task.value
        #expect(received == nil)
    }

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)

    @Test func sendDeliversFIFOAcrossMultipleNexts() async throws {
        let probe = AsyncProbe<Int>()
        for i in 0..<5 { probe.send(i) }
        for i in 0..<5 {
            let received = try await probe.next()
            #expect(received == i)
        }
    }

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)

    @Test func expectNoBufferedElementsPassesOnEmpty() throws {
        let probe = AsyncProbe<Int>()
        try probe.expectNoBufferedElements()
    }

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)

    @Test func expectNoBufferedElementsThrowsWhenStrayPresent() throws {
        let probe = AsyncProbe<Int>()
        probe.send(99)
        #expect(throws: AsyncProbeError.self) {
            try probe.expectNoBufferedElements()
        }
    }

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)

    @Test func expectNoBufferedElementsClosesTheProbe() async throws {
        let probe = AsyncProbe<Int>()
        try probe.expectNoBufferedElements()
        // Subsequent sends are dropped silently. next() returns nil.
        probe.send(1)
        let received = try await probe.next()
        #expect(received == nil)
    }

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)

    @Test func cancellationOfNextThrows() async throws {
        let probe = AsyncProbe<Int>()
        let task = Task { try await probe.next() }
        task.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)

    @Test func gateSignalledSendResumesQueuedNext() async throws {
        // Cross-test using TaskGate as the production-shape signal.
        let probe = AsyncProbe<String>()
        let gate = TaskGate()

        let receiver = Task { try await probe.next() }
        // Production-shape sender: waits on gate, then sends.
        let sender = Task {
            try await gate.wait()
            probe.send("post-gate")
        }
        gate.open()
        _ = try await sender.value
        let received = try await receiver.value
        #expect(received == "post-gate")
    }
}

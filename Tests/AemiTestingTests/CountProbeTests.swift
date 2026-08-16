import Testing

@testable import AemiTesting

/// `CountProbe` regression coverage: threshold waits, the count-only `Never` specialization,
/// diagnostic timeout errors, and cancellation propagation.
@Suite("CountProbe")
struct CountProbeTests {

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)

    @Test func waitReturnsOnceThresholdAlreadyMet() async throws {
        let probe = CountProbe<Int>()
        probe.record(1)
        probe.record(2)
        probe.record(3)
        try await probe.wait(forAtLeast: 3)
        #expect(probe.events == [1, 2, 3])
        #expect(probe.count == 3)
        #expect(!probe.isEmpty)
    }

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)

    @Test func waitSuspendsUntilThresholdReached() async throws {
        let probe = CountProbe<String>()
        let waiter = Task {
            try await probe.wait(forAtLeast: 2)
        }
        probe.record("a")
        probe.record("b")
        try await waiter.value
        #expect(probe.events == ["a", "b"])
    }

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)

    @Test func countOnlyProbeCountsWithoutStoringEvents() async throws {
        let probe = CountProbe()  // no generic argument: Event resolves to Never
        #expect(probe.isEmpty)
        probe.record()
        probe.record()
        try await probe.wait(forAtLeast: 2)
        #expect(probe.count == 2)
        #expect(probe.events.isEmpty)
        #expect(!probe.isEmpty)
    }

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)

    @Test func timeoutThrowsDiagnosticError() async throws {
        let probe = CountProbe<Int>(label: "boundary")
        probe.record(7)
        do {
            try await probe.wait(forAtLeast: 2, timeout: .milliseconds(50))
            Issue.record("Expected wait(forAtLeast:) to time out")
        } catch let error as CountProbeTimeoutError<Int> {
            #expect(error.label == "boundary")
            #expect(error.expected == 2)
            #expect(error.recordedCount == 1)
            #expect(error.recorded == [7])
            #expect("\(error.file)".contains("CountProbeTests"))
            #expect(error.description.contains("CountProbe 'boundary'"))
            #expect(error.description.contains("expected at least 2, recorded 1"))
        }
    }

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)

    @Test func cancellationPropagatesToWaiter() async throws {
        let probe = CountProbe<Int>()
        let waiter = Task {
            try await probe.wait(forAtLeast: 1)
        }
        waiter.cancel()
        await #expect(throws: CancellationError.self) {
            try await waiter.value
        }
    }
}

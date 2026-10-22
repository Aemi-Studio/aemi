import Foundation
import Testing

@testable import AemiTestKit

@Suite(.tags(.concurrency))
struct ThreadGateTests {
    @Test
    func `an initially-open gate does not block`() {
        let gate = ThreadGate(initiallyOpen: true)
        gate.waitUntilOpen()  // if it blocked, this test would hang
    }

    @Test
    func `open() releases a waiter blocked on a closed gate`() async throws {
        let gate = ThreadGate()
        let passed = AsyncEventProbe<Int>()
        // Block off the cooperative pool so we never starve a runtime thread.
        DispatchQueue.global()
            .async {
                gate.waitUntilOpen()
                passed.record(1)
            }
        gate.open()
        let events = try await passed.wait(forAtLeast: 1, timeout: .seconds(2))
        #expect(events == [1])
    }

    @Test
    func `withThreadGatedBatch resumes the holder only after the gate is opened`() async {
        let order = AsyncEventProbe<String>()
        await withThreadGatedBatch(
            hold: { gate in
                order.record("holder-start")
                gate.waitUntilOpen()
                order.record("holder-resumed")
            },
            { openGate in
                order.record("body")
                openGate()
            })
        // The holder can only resume after the body opened the gate, so its resume is
        // always the final recorded event regardless of how start/body interleave.
        #expect(order.count == 3)
        #expect(order.events.last == "holder-resumed")
        #expect(order.events.contains("body"))
    }

    @Test
    func `withThreadGatedBatch opens the gate and joins the holder when the body throws`() async {
        struct Failure: Error {}
        let order = AsyncEventProbe<String>()
        await #expect(throws: Failure.self) {
            try await withThreadGatedBatch(
                hold: { gate in
                    order.record("holder-start")
                    gate.waitUntilOpen()
                    order.record("holder-resumed")
                },
                { _ in throw Failure() })
        }
        // The holder thread was released and joined before the error propagated, not left blocked.
        #expect(order.events.last == "holder-resumed")
    }
}

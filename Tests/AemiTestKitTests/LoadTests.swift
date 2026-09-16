import Synchronization
import Testing

@testable import AemiTestKit

@Suite(.tags(.concurrency))
struct LoadTests {
    @Test
    func `expectAllConcurrent runs every worker and reports all successes`() async {
        let counter = Atomic<Int>(0)
        let outcome = await expectAllConcurrent(count: 50) { _ in
            counter.add(1, ordering: .relaxed)
            return 1
        }
        #expect(outcome.complete)
        #expect(outcome.successCount == 50)
        #expect(outcome.failureCount == 0)
        #expect(counter.load(ordering: .relaxed) == 50)
        #expect(outcome.successes.reduce(0, +) == 50)
    }

    @Test
    func `expectExactlyKSucceed asserts an admission limiter admits exactly K`() async {
        // A lock-free K-slot admission gate, like ConnectionLimiter: CAS up to K, reject past it. Under a
        // thundering-herd release all 40 race for the 8 slots at once.
        let admitted = Atomic<Int>(0)
        let limit = 8
        struct Rejected: Error {}
        let outcome = await expectExactlyKSucceed(of: 40, succeed: limit) { _ in
            var current = admitted.load(ordering: .relaxed)
            while current < limit {
                let (exchanged, original) = admitted.compareExchange(
                    expected: current, desired: current + 1, ordering: .relaxed)
                if exchanged { return }  // admitted
                current = original
            }
            throw Rejected()  // over capacity
        }
        #expect(outcome.successCount == limit)
        #expect(outcome.failureCount == 40 - limit)
    }

    @Test
    func `a worker that overruns the deadline is reported timed out, not hung`() async throws {
        let gate = AsyncGate()
        var recorded: LoadOutcome<Void>?
        await withKnownIssue {
            recorded = await expectAllConcurrent(count: 1, within: .milliseconds(150)) { _ in
                try await gate.waitUntilOpen()
            }
        }
        let outcome = try #require(recorded)
        #expect(!outcome.complete)
        #expect(outcome.successCount == 0)
        #expect(outcome.results.count == 1)
        #expect(
            outcome.results.contains { result in
                guard case .failure(let error) = result else { return false }
                return error.typeName.contains("LoadWorkerTimedOut")
            })
    }
}

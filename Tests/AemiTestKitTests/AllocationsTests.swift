import Foundation
import Testing

@testable import AemiTestKit

// Serialized so this suite's measurements run one at a time. Counts cover only the measuring thread,
// so suites running alongside cannot inflate them.
@Suite(.serialized)
struct AllocationsTests {
    @Test
    func `allocation counting is available on Darwin`() {
        #if canImport(Darwin)
            // Under a sanitizer the interposed allocator bypasses the default-zone logger, so the
            // kit deliberately reports unavailable there (and the measuring tests below no-op).
            #expect(allocationCountingAvailable == !sanitizerRuntimeLoaded)
        #endif
    }

    @Test
    func `mallocDelta observes a heap allocation`() {
        guard allocationCountingAvailable else { return }  // covered by the benchmark malloc metric elsewhere
        var sink: [UInt8] = []
        _ = mallocDelta { sink = [UInt8](repeating: 0, count: 4096) }  // warm up (lazy init)
        let count = mallocDelta { sink = [UInt8](repeating: 1, count: 4096) }
        _ = sink
        #expect(count != nil)
        #expect((count ?? 0) >= 1)  // a 4 KiB Array is a real heap allocation
    }

    @Test
    func `expectAllocations passes under a generous budget and trips a zero budget`() {
        guard allocationCountingAvailable else { return }
        var sink: [UInt8] = []
        _ = mallocDelta { sink = [UInt8](repeating: 0, count: 1024) }  // warm up
        // A generous ceiling never trips on a single small allocation (robust to noise on the measuring thread).
        expectAllocations(noMoreThan: 100_000) { sink = [UInt8](repeating: 0, count: 1024) }
        // A zero budget MUST trip on a real allocation — `withKnownIssue` absorbs the recorded failure.
        withKnownIssue {
            expectAllocations(noMoreThan: 0) { sink = [UInt8](repeating: 0, count: 1024) }
        }
        _ = sink
    }

    /// A ceiling must fail only when its own body allocates, never because another thread allocated while it
    /// measured. Both runs start, and wait for, one thread; only the second thread allocates, 10,000 times.
    @Test
    func `allocations another thread makes during a measurement are not counted`() throws {
        guard allocationCountingAvailable else { return }
        _ = countWhileAnotherThreadAllocates(0)  // warm up thread creation
        let quiet = try #require(countWhileAnotherThreadAllocates(0))
        let busy = try #require(countWhileAnotherThreadAllocates(10_000))
        #expect(busy - quiet < 100, "another thread's allocations leaked in: quiet \(quiet), busy \(busy)")
    }

    private func countWhileAnotherThreadAllocates(_ allocations: Int) -> Int? {
        let finished = DispatchSemaphore(value: 0)
        return mallocDelta {
            let worker = Thread {
                var sink: [[UInt8]] = []
                for index in 0 ..< allocations {
                    sink.append([UInt8](repeating: UInt8(truncatingIfNeeded: index), count: 32))
                }
                precondition(sink.count == allocations)
                finished.signal()
            }
            worker.start()
            finished.wait()
        }
    }

    /// Parallel tests may each measure at once. Overlapping measurements used to corrupt the hook chain:
    /// the second one saved the counting hook itself as the hook to chain to, so every later allocation
    /// recursed until the stack overflowed. That kills the process, hence the child process here, which
    /// also checks that counting still works once the measurements are done.
    @Test
    func `measurements from several threads at once leave allocation counting intact`() async {
        await #expect(processExitsWith: .success) {
            await withTaskGroup(of: Void.self) { group in
                for _ in 0 ..< 8 {
                    group.addTask {
                        var sink: [UInt8] = []
                        for round in 0 ..< 20_000 {
                            _ = mallocDelta { sink = [UInt8](repeating: UInt8(truncatingIfNeeded: round), count: 64) }
                        }
                        _ = sink
                    }
                }
            }
            var sink: [UInt8] = []
            let count = mallocDelta { sink = [UInt8](repeating: 1, count: 4096) }
            _ = sink
            precondition(count != 0, "allocation counting stopped observing allocations")
        }
    }
}

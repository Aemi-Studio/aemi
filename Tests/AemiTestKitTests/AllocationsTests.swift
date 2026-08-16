import Testing

@testable import AemiTestKit

// Serialized: the malloc counter is PROCESS-WIDE, so concurrent allocation in a sibling test would add
// noise. Assertions are written to tolerate upward noise (`>= 1`, a generous ceiling, and a budget of 0
// that any real allocation trips) so they never flake even if some leaks through.
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
        // A generous ceiling never trips on a single small allocation (robust to process-wide noise).
        expectAllocations(noMoreThan: 100_000) { sink = [UInt8](repeating: 0, count: 1024) }
        // A zero budget MUST trip on a real allocation — `withKnownIssue` absorbs the recorded failure.
        withKnownIssue {
            expectAllocations(noMoreThan: 0) { sink = [UInt8](repeating: 0, count: 1024) }
        }
        _ = sink
    }
}

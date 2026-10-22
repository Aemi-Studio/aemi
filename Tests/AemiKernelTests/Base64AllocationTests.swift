import AemiKernel
import AemiTestKit
import Testing

// The malloc counter is process-wide, so a measurement taken next to other running tests also counts
// their allocations. Each guard therefore runs in its own child process (an exit test), where nothing
// else runs, and keeps the fewest allocations seen over several runs. Counting is unavailable under a
// sanitizer and off Darwin, where the guards run the body and measure nothing. Only contiguous input and
// only success are guarded: in a -Onone build both a `for … in` over an arbitrary `Collection` and a
// thrown error allocate, which says nothing about the optimized path.

private let sampleText = Array("Zm9vYmFyZm9vYmFyZm9vYmFyZm9vYmFyZm9vYmFyZm9vYmFyZm9vYmE=".utf8)
private let sampleBytes = (0 ..< 1_000).map { UInt8(truncatingIfNeeded: $0) }

/// Traps unless `body` allocates at most `limit` times per run, measured as the minimum of 50 runs after
/// a warm-up (which pays for lazy statics).
private func requireAllocations(atMost limit: Int, _ what: String, _ body: () -> Void) {
    guard allocationCountingAvailable else {
        body()
        return
    }
    body()
    var fewest = Int.max
    for _ in 0 ..< 50 { fewest = Swift.min(fewest, mallocDelta(body) ?? 0) }
    if fewest > limit {
        print("\(what): measured \(fewest) allocation(s), expected at most \(limit)")
        fatalError("allocation guard failed: \(what)")
    }
}

struct Base64AllocationTests {
    @Test func decodeIntoAllocatesNothing() async {
        await #expect(processExitsWith: .success) {
            var storage = [UInt8](repeating: 0, count: 64)
            requireAllocations(atMost: 0, "decode(into:)") {
                _ = try? storage.withUnsafeMutableBufferPointer { out in
                    try Base64.decode(sampleText, into: out, options: .strict)
                }
                _ = try? storage.withUnsafeMutableBufferPointer { out in
                    try Base64.decode(sampleText, into: out, options: .pem)
                }
            }
        }
    }

    @Test func decodeAllocatesOnlyTheResult() async {
        await #expect(processExitsWith: .success) {
            requireAllocations(atMost: 1, "decode [UInt8]") { _ = try? Base64.decode(sampleText, options: .strict) }
            requireAllocations(atMost: 1, "decode ArraySlice") {
                _ = try? Base64.decode(sampleText[...], options: .strict)
            }
            requireAllocations(atMost: 1, "decode String") {
                _ = try? Base64.decode("Zm9vYmFyZm9vYmE=", options: .strict)
            }
            requireAllocations(atMost: 1, "decode lenient nil API") { _ = Base64.decode(sampleText) }
        }
    }

    @Test func encodeIntoAllocatesNothing() async {
        await #expect(processExitsWith: .success) {
            var storage = [UInt8](repeating: 0, count: 2_000)
            requireAllocations(atMost: 0, "encode(into:)") {
                _ = try? storage.withUnsafeMutableBufferPointer { out in
                    try Base64.encode(sampleBytes, into: out, options: .pem)
                }
                _ = try? storage.withUnsafeMutableBufferPointer { out in
                    try Base64.encode(sampleBytes, into: out, options: .urlSafeNoPadding)
                }
            }
        }
    }

    @Test func encodeAllocatesOnlyTheResult() async {
        await #expect(processExitsWith: .success) {
            requireAllocations(atMost: 1, "encode strict") { _ = Base64.encode(sampleBytes, options: .strict) }
            requireAllocations(atMost: 1, "encode mime") { _ = Base64.encode(sampleBytes, options: .mime) }
            requireAllocations(atMost: 1, "encode legacy overload") { _ = Base64.encode(sampleBytes) }
        }
    }

    @Test func theGuardCatchesARealAllocation() async {
        await #expect(processExitsWith: .failure) {
            guard allocationCountingAvailable else { fatalError("counting unavailable") }  // vacuous pass
            requireAllocations(atMost: 0, "control") { _ = [UInt8](repeating: 1, count: 4_096) }
        }
    }
}

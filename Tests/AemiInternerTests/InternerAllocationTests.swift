import AemiInterner
import AemiTestKit
import Testing

// As in AemiKernelTests' Base64AllocationTests: the counter is per thread, but a measurement next to other running tests
// is noisy, so each guard runs in its own child process and keeps the fewest allocations over 50 runs after a warm-up.
// Counting is unavailable under a sanitizer and off Darwin, where the guards measure nothing.

/// Traps unless `body` allocates at most `limit` times per run.
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

private let words: [String] = (0 ..< 200).map { "s:14OculavisShareIOS\($0)ViewModelC6update_2bySS_SitF" }
private let wordBytes: [[UInt8]] = words.map { Array($0.utf8) }

/// Interning never makes a `String`: a repeated key, from bytes or from a `String`, allocates nothing, and neither does
/// a new key while the table and the chunk have room (ADR 0019).
struct InternerAllocationTests {
    @Test func `interning a known key allocates nothing`() async {
        await #expect(processExitsWith: .success) {
            let interner = Interner()
            for word in words { _ = interner.intern(word) }
            requireAllocations(atMost: 0, "intern known bytes") {
                for word in wordBytes { _ = word.withUnsafeBytes { interner.intern($0) } }
            }
            requireAllocations(atMost: 0, "intern known String") {
                for word in words { _ = interner.intern(word) }
            }
            requireAllocations(atMost: 0, "look up and resolve") {
                for word in words {
                    if let symbol = interner.symbol(for: word) { _ = interner.withBytes(of: symbol) { $0.count } }
                }
            }
            precondition(interner.count == words.count)
        }
    }

    @Test func `interning a new key within the capacity reserved allocates nothing`() async {
        await #expect(processExitsWith: .success) {
            let fresh: [[UInt8]] = (0 ..< 60).map { Array("fresh-key-\($0)-of-a-usr-like-length-0123456789".utf8) }
            let interner = Interner(capacity: 1_024, byteCapacity: 1 << 16)
            var next = 0
            requireAllocations(atMost: 0, "intern a new key") {
                _ = fresh[next].withUnsafeBytes { interner.intern($0) }
                next += 1
            }
            precondition(interner.count == 51)
        }
    }
}

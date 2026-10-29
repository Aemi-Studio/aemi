import AemiInterner
import AemiTestKit
import Testing

// As in AemiKernelTests' Base64AllocationTests: each guard runs in its own child process and keeps the fewest allocations
// over 50 runs after a warm-up. Each body is one call on bytes made beforehand: in a -Onone build a `for … in` loop and
// `Array.withUnsafeBytes` allocate on their own (measured: twice per element), which says nothing about the interner.
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

/// `text`'s UTF-8 in memory of its own, never freed (the child process exits).
private func storedBytes(_ text: String) -> UnsafeRawBufferPointer {
    let stored = UnsafeMutableRawBufferPointer.allocate(byteCount: text.utf8.count, alignment: 8)
    _ = stored.initializeMemory(as: UInt8.self, from: text.utf8)
    return UnsafeRawBufferPointer(stored)
}

/// Interning never makes a `String`: a repeated key, from bytes or from a `String`, allocates nothing, and neither does
/// a new key while the table and the chunk have room (ADR 0019).
struct InternerAllocationTests {
    @Test func `interning a known key allocates nothing`() async {
        await #expect(processExitsWith: .success) {
            let interner = Interner()
            for word in words { _ = interner.intern(word) }
            let key: String = words[7]
            let bytes: UnsafeRawBufferPointer = storedBytes(key)
            requireAllocations(atMost: 0, "intern known bytes") { _ = interner.intern(bytes) }
            requireAllocations(atMost: 0, "intern known String") { _ = interner.intern(key) }
            requireAllocations(atMost: 0, "look up") { _ = interner.symbol(for: key) }
            requireAllocations(atMost: 0, "resolve") { _ = interner.withBytes(of: Symbol(rawValue: 7)) { $0.count } }
            let frozen: FrozenInterner = interner.freeze()
            requireAllocations(atMost: 0, "look up frozen") { _ = frozen.symbol(for: bytes) }
            precondition(interner.count == words.count)
        }
    }

    @Test func `interning a new key within the capacity reserved allocates nothing`() async {
        await #expect(processExitsWith: .success) {
            let keys: [UnsafeRawBufferPointer] = (0 ..< 60)
                .map { storedBytes("fresh-key-\($0)-of-a-usr-like-length-0123456789") }
            let interner = Interner(capacity: 1_024, byteCapacity: 1 << 16)
            var next = 0
            requireAllocations(atMost: 0, "intern a new key") {
                _ = interner.intern(keys[next])
                next += 1
            }
            // Without counting, the body ran once.
            precondition(interner.count == (allocationCountingAvailable ? 51 : 1))
        }
    }
}

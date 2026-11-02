import AemiKernels
import AemiTestKit
import Testing

/// The search facade with the haystack and the needle flush against inaccessible pages (aemi ADR 0021).
struct AemiKernelsFindTests {
    @Test func `searches stay inside a haystack and a needle that end at a guard page`() {
        for edge in GuardedBytes.Edge.allCases {
            for count in Array(0 ... 130) + [255, 256, 257, 4095, 4096, 4097] {
                let bytes = (0 ..< count).map { UInt8(ascii: "a") + UInt8($0 % 3) }
                for needleLength in [1, 2, 3, 15, 16, 17, 33] where needleLength <= max(count, 1) {
                    // A needle that is the haystack's last bytes, and one that never occurs.
                    let present = Array(bytes.suffix(needleLength))
                    let absent = [UInt8](repeating: UInt8(ascii: "z"), count: needleLength)
                    for needle in [present, absent] {
                        GuardedBytes.with(bytes, against: edge) { hay in
                            GuardedBytes.with(needle, against: edge) { pattern in
                                let found = AemiKernels.firstIndex(
                                    of: UnsafeBufferPointer(start: pattern, count: needle.count),
                                    in: UnsafeBufferPointer(start: hay, count: count)
                                )
                                let expected = (0 ... max(0, count - needle.count))
                                    .first {
                                        $0 + needle.count <= count && Array(bytes[$0 ..< $0 + needle.count]) == needle
                                    }
                                #expect(
                                    found == (needle.isEmpty ? 0 : expected),
                                    "length \(count) needle \(needle.count)"
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

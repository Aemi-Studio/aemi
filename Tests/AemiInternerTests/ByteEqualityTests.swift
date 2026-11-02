import AemiTestKit
import Testing

@testable import AemiInterner

/// The interner's key comparison: right at every length around its 16-, 8- and 4-byte steps, for a difference at every
/// position and in any bit, and never reading past either buffer (each ends against an inaccessible page).
struct ByteEqualityTests {
    static let lengths: [Int] = Array(0 ... 80) + [127, 128, 129, 255, 256, 4095, 4096]

    @Test func `equal bytes are equal at every length, against a guard page at either end`() {
        for edge in GuardedBytes.Edge.allCases {
            for count in Self.lengths {
                let bytes: [UInt8] = (0 ..< count)
                    .map { (index: Int) -> UInt8 in UInt8(truncatingIfNeeded: index &* 37 &+ 11) }
                let equal: Bool = Self.compare(bytes, bytes, edge: edge)
                #expect(equal, "length \(count)")
            }
        }
    }

    @Test func `a difference at any position and in any bit is seen`() {
        for count in Self.lengths where count > 0 && count <= 129 {
            let bytes: [UInt8] = (0 ..< count)
                .map { (index: Int) -> UInt8 in UInt8(truncatingIfNeeded: index &* 29 &+ 3) }
            for position in 0 ..< count {
                for bit in [0, 7] {
                    var other: [UInt8] = bytes
                    other[position] ^= UInt8(1) << UInt8(bit)
                    let equal: Bool = Self.compare(bytes, other, edge: position.isMultiple(of: 2) ? .end : .start)
                    #expect(!equal, "length \(count), byte \(position), bit \(bit)")
                }
            }
        }
    }

    @Test func `buffers of different lengths differ, even when one is a prefix of the other`() {
        let bytes: [UInt8] = Array(repeating: 0x61, count: 40)
        for count in 0 ..< 40 {
            let equal: Bool = Self.compare(Array(bytes[..<count]), bytes, edge: .end)
            #expect(!equal, "length \(count) against 40")
        }
    }

    /// `bytesEqual` over copies of `a` and `b`, each flush against an inaccessible page at `edge`.
    private static func compare(_ a: [UInt8], _ b: [UInt8], edge: GuardedBytes.Edge) -> Bool {
        GuardedBytes.with(a, against: edge) { left in
            GuardedBytes.with(b, against: edge) { right in
                unsafe bytesEqual(
                    UnsafeRawBufferPointer(start: left, count: a.count),
                    UnsafeRawBufferPointer(start: right, count: b.count)
                )
            }
        }
    }
}

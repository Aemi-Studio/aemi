import AemiKernels
import Testing

/// `AemiKernels.SmallByteSet`, promoted from AemiRegex's prefilter (aemi ADR 0017), against a naive scan, at every length around the
/// vector width and from every start offset.
struct AemiKernelsSmallByteSetTests {
    private static let sizes = [0, 1, 2, 15, 16, 17, 31, 32, 33, 63, 64, 65, 100, 257]

    private static func buffer(size: Int, seed: UInt8) -> [UInt8] {
        (0 ..< size)
            .map { i in
                let mixed = UInt8(truncatingIfNeeded: i &* 37 &+ Int(seed) &* 11)
                return mixed % 7 == 0 ? 0x61 : (mixed % 11 == 0 ? 0x62 : 0x78)
            }
    }

    @Test(arguments: sizes)
    func `any byte of the set is found at the first position, from every start`(size: Int) throws {
        let bytes = Self.buffer(size: size, seed: 9)
        let sets: [[UInt8]] = [
            [0x61], [0x61, 0x62], [0x62, 0x7A], [0x61, 0x62, 0x78, 0x7A, 0x41, 0x42, 0x43, 0x44], [0x7A, 0x7B]
        ]
        for members in sets {
            let set = try #require(AemiKernels.SmallByteSet(members))
            for from in 0 ... size {
                let expected = (from ..< size).first { members.contains(bytes[$0]) }
                let actual = bytes.withUnsafeBufferPointer { set.firstIndex(in: $0, from: from) }
                #expect(actual == expected, "set \(members) from \(from) in \(size) bytes")
            }
        }
    }

    @Test func `an empty set and one of more than eight bytes are refused`() {
        #expect(AemiKernels.SmallByteSet([]) == nil)
        #expect(AemiKernels.SmallByteSet(Array(0 ..< 9)) == nil)
        #expect(AemiKernels.SmallByteSet(Array(0 ..< 8)) != nil)
    }

    /// The bytes just past the end are members, so a scan that reads past the end reports a position it must not.
    @Test(arguments: sizes)
    func `the scan never reads past the end of the buffer`(size: Int) throws {
        let set = try #require(AemiKernels.SmallByteSet([0x62]))
        let storage = [UInt8](repeating: 0x78, count: size) + [UInt8](repeating: 0x62, count: 32)
        storage.withUnsafeBufferPointer { whole in
            let body = UnsafeBufferPointer(rebasing: whole[0 ..< size])
            #expect(set.firstIndex(in: body, from: 0) == nil, "\(size) bytes")
            #expect(set.firstIndex(in: body, from: size + 1) == nil && set.firstIndex(in: body, from: -1) == nil)
        }
    }
}

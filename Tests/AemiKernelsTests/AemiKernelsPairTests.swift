import AemiKernels
import Testing

/// `AemiKernels.firstIndex(ofPair:_:in:from:)`, promoted from AemiRegex (aemi ADR 0018), against a naive scan, at every length around
/// the vector width and from every start offset.
struct AemiKernelsPairTests {
    private static let sizes = [0, 1, 2, 15, 16, 17, 18, 31, 32, 33, 63, 64, 65, 100, 257]

    /// A buffer of `size` bytes from a small alphabet, so every needle occurs, with dense and sparse runs.
    private static func buffer(size: Int, seed: UInt8) -> [UInt8] {
        (0 ..< size)
            .map { i in
                let mixed = UInt8(truncatingIfNeeded: i &* 37 &+ Int(seed) &* 11)
                return mixed % 7 == 0 ? 0x61 : (mixed % 11 == 0 ? 0x62 : 0x78)
            }
    }

    @Test(arguments: sizes)
    func `a byte pair is found only where both bytes are adjacent, from every start`(size: Int) {
        let bytes = Self.buffer(size: size, seed: 5)
        for (first, second): (UInt8, UInt8) in [(0x61, 0x62), (0x78, 0x78), (0x62, 0x61), (0x7A, 0x61)] {
            for from in 0 ... size {
                let expected = (from ..< size).first { $0 + 1 < size && bytes[$0] == first && bytes[$0 + 1] == second }
                let actual = bytes.withUnsafeBufferPointer {
                    AemiKernels.firstIndex(ofPair: first, second, in: $0, from: from)
                }
                #expect(actual == expected, "pair \(first),\(second) from \(from) in \(size) bytes")
            }
        }
    }

    @Test func `a start outside the buffer finds nothing`() {
        let bytes: [UInt8] = [0x61, 0x61]
        bytes.withUnsafeBufferPointer {
            #expect(AemiKernels.firstIndex(ofPair: 0x61, 0x61, in: $0, from: 2) == nil)
            #expect(AemiKernels.firstIndex(ofPair: 0x61, 0x61, in: $0, from: -1) == nil)
            #expect(AemiKernels.firstIndex(ofPair: 0x61, 0x61, in: $0, from: 0) == 0)
        }
    }

    /// The byte just past the end completes a pair, so a scan that reads past the end reports a position it must not.
    @Test(arguments: sizes)
    func `the scan never reads past the end of the buffer`(size: Int) {
        guard size > 0 else { return }
        var storage = [UInt8](repeating: 0x78, count: size)
        storage[size - 1] = 0x61
        storage += [UInt8](repeating: 0x62, count: 32)
        storage.withUnsafeBufferPointer { whole in
            let body = UnsafeBufferPointer(rebasing: whole[0 ..< size])
            #expect(AemiKernels.firstIndex(ofPair: 0x61, 0x62, in: body, from: 0) == nil, "\(size) bytes")
        }
    }
}

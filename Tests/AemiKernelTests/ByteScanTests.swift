import AemiKernel
import AemiKernels
import AemiTestKit
import Testing

/// `ByteScan` (ADR 0031) against plain loops: the SWAR front, the kernel behind it and their boundary at 32 bytes, over ranges
/// that start and end anywhere, inputs mostly plain with needles, controls, non-ASCII and bytes one bit away from a needle (the
/// lanes a SWAR borrow could flag).
struct ByteScanTests {
    static let needles: [UInt8] = [0x22, 0x5C, 0x0A, 0x0D, 0x7B]

    static func input(_ generator: inout SeededRNG, count: Int) -> [UInt8] {
        (0 ..< count)
            .map { _ -> UInt8 in
                switch generator.int(40) {
                    case 0: needles[generator.int(needles.count)]
                    case 1: 0x23  // `"` + 1
                    case 2: 0x00
                    case 3: 0xFF
                    case 4: 0x1F
                    case 5: 0x20
                    case 6: 0x09
                    default: UInt8(0x30 + generator.int(0x4B))
                }
            }
    }

    static func ranges(_ generator: inout SeededRNG, count: Int) -> [(Int, Int)] {
        (0 ..< 6)
            .map { _ in
                let start = generator.int(count + 2)
                return (start, start + generator.int(count + 3))
            }
    }

    static func reference(_ bytes: [UInt8], _ start: Int, _ end: Int, _ stop: (UInt8) -> Bool) -> Int {
        let end = min(end, bytes.count)
        guard start < end else { return max(start, max(end, 0)) }
        return (start ..< end).first { stop(bytes[$0]) } ?? end
    }

    @Test func `every scan finds what a loop finds, from anywhere to anywhere`() {
        var generator = SeededRNG(seed: 0xB7E5_CA11)
        var checked = 0
        for _ in 0 ..< 3000 {
            let bytes = Self.input(&generator, count: generator.int(140))
            let contiguous = ContiguousArray(bytes)
            for (start, end) in Self.ranges(&generator, count: bytes.count) {
                let any = Self.reference(bytes, start, end) { Self.needles.contains($0) }
                #expect(ByteScan.firstIndexOfAny(in: bytes, from: start, to: end, 0x22, 0x5C, 0x0A, 0x0D, 0x7B) == any)
                #expect(
                    ByteScan.firstIndexOfAny(in: contiguous, from: start, to: end, 0x22, 0x5C, 0x0A, 0x0D, 0x7B) == any
                )
                #expect(
                    ByteScan.firstIndex(of: 0x5C, in: bytes, from: start, to: end)
                        == Self.reference(bytes, start, end) { $0 == 0x5C }
                )
                #expect(
                    ByteScan.indexOfControlOrAny(in: bytes, from: start, to: end, 0x22, 0x22, 0x22, 0x22, 0x7B)
                        == Self.reference(bytes, start, end) { $0 < 0x20 || $0 == 0x22 || $0 == 0x7B }
                )
                #expect(
                    ByteScan.firstIndexNotEither(0x20, 0x09, in: bytes, from: start, to: end)
                        == Self.reference(bytes, start, end) { $0 != 0x20 && $0 != 0x09 }
                )
                if let set = AemiKernels.ByteSet([0x22, 0x7B, 0x30, 0x31]) {
                    #expect(
                        ByteScan.firstIndex(inSet: set, in: bytes, from: start, to: end)
                            == Self.reference(bytes, start, end) { set.contains($0) }
                    )
                    #expect(
                        ByteScan.firstIndex(notInSet: set, in: bytes, from: start, to: end)
                            == Self.reference(bytes, start, end) { !set.contains($0) }
                    )
                }
                checked += 1
            }
        }
        #expect(checked == 18_000)
    }

    @Test func `long runs of indentation end where a loop says, past the SWAR words`() {
        for count in 0 ..< 300 {
            for tail: UInt8 in [0x61, 0x21, 0x08, 0x0A] {
                let bytes = (0 ..< count).map { $0 % 3 == 0 ? UInt8(0x09) : 0x20 } + [tail]
                #expect(ByteScan.firstIndexNotEither(0x20, 0x09, in: bytes, from: 0) == count)
            }
        }
    }

    @Test func `UTF-8 validity over a range, and positions of either byte appended in order`() {
        var generator = SeededRNG(seed: 0x0FF5_E75)
        for _ in 0 ..< 2000 {
            let bytes = Self.input(&generator, count: generator.int(300))
            let invalid = AemiKernels.firstInvalidUTF8(bytes)
            #expect(ByteScan.firstInvalidUTF8(in: bytes) == invalid)
            var positions: [UInt32] = [7]
            let start = generator.int(bytes.count + 1)
            AemiKernels.appendPositions(ofEither: 0x0A, 0x0D, in: bytes, from: start, into: &positions)
            let expected =
                [UInt32(7)]
                + (start ..< bytes.count).filter { bytes[$0] == 0x0A || bytes[$0] == 0x0D }.map { UInt32($0) }
            #expect(positions == expected)
        }
        // A dense input fills the room the first pass gives, and the rest is resumed.
        let dense = [UInt8](repeating: 0x0A, count: 5000)
        var all: [UInt32] = []
        AemiKernels.appendPositions(ofEither: 0x0A, 0x0D, in: dense, into: &all)
        #expect(all == (0 ..< 5000).map { UInt32($0) })
    }

    @Test func `SWAR lane tests are exact in every lane`() {
        var generator = SeededRNG(seed: 0x5A5A)
        for _ in 0 ..< 20_000 {
            var lanes = (0 ..< 8).map { _ in UInt8(generator.int(256)) }
            if generator.int(2) == 0 { lanes[generator.int(8)] = 0 }
            if generator.int(2) == 0 { lanes[generator.int(8)] = 0x20 }
            let word = lanes.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
            for (lane, byte) in lanes.enumerated() {
                let bit = UInt64(0x80) << (8 * UInt64(lane))
                #expect((SWAR.nonZeroLanes(word) & bit != 0) == (byte != 0))
                #expect((SWAR.equalLanes(word, 0x20) & bit != 0) == (byte == 0x20))
                #expect((SWAR.neitherLanes(word, 0x20, 0x09) & bit != 0) == (byte != 0x20 && byte != 0x09))
            }
        }
    }
}

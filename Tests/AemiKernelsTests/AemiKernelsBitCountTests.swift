import AemiKernels
import Testing

// Set bits in a buffer (allocation bitmaps): `.fastest` (NEON `cnt`) equals `.scalar` and `nonzeroBitCount`, across the
// 16-byte and flush-block boundaries.
struct AemiKernelsBitCountTests {
    static func count(_ bytes: [UInt8], _ backend: AemiKernels.Backend) -> Int {
        bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return 0 }
            return AemiKernels.bitCount(base, count: buffer.count, backend: backend)
        }
    }

    @Test func everyLengthAndAFlushBlockMatchTheReference() {
        var state: UInt32 = 7
        for length in Array(0 ... 300) + [2048 * 16 - 1, 2048 * 16, 2048 * 16 + 17, 300_001] {
            let bytes = (0 ..< length)
                .map { _ -> UInt8 in
                    state = state &* 1_664_525 &+ 1_013_904_223
                    return UInt8(truncatingIfNeeded: state >> 24)
                }
            let expected = bytes.reduce(0) { $0 + $1.nonzeroBitCount }
            #expect(Self.count(bytes, .fastest) == expected, "fastest, \(length)")
            #expect(Self.count(bytes, .scalar) == expected, "scalar, \(length)")
        }
    }

    @Test func allOnesNeverWrapALane() {
        let ones = [UInt8](repeating: 0xFF, count: 2048 * 16 * 3 + 5)
        #expect(Self.count(ones, .fastest) == ones.count * 8)
    }
}

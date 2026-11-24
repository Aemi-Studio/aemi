import AemiKernels
import Testing

/// 4-byte repeating XOR mask (`buf[i] ^= mask[i & 3]`, RFC 6455 WebSocket masking).
/// Verifies `.fastest` (NEON/SSE2 64-byte unrolled) matches `.scalar` across all lengths & alignments,
/// and is a strict involution.
struct AemiKernelsXORMask4Tests {
    @Test func everyLengthAndAlignmentMatchesScalarAndIsInvolution() {
        var state: UInt64 = 0xD1B5_4A32_D192_ED03
        let original = (0 ..< 1040)
            .map { _ -> UInt8 in
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return UInt8(truncatingIfNeeded: state >> 33)
            }
        let mask: UInt32 = 0x37FA_213D

        for offset in [0, 1, 2, 3, 7, 15] {
            for length in Array(0 ... 160) + [255, 256, 257, 511, 512, 1024] {
                var fast = Array(original[0 ..< (offset + length)])
                var slow = fast
                fast.withUnsafeMutableBufferPointer { buf in
                    guard let base = buf.baseAddress else { return }
                    AemiKernels.xorMask4(base + offset, count: length, mask: mask, backend: .fastest)
                }
                slow.withUnsafeMutableBufferPointer { buf in
                    guard let base = buf.baseAddress else { return }
                    AemiKernels.xorMask4(base + offset, count: length, mask: mask, backend: .scalar)
                }
                #expect(fast == slow, "mismatch length=\(length) offset=\(offset)")

                // Applying the same mask a second time must recover the exact original bytes.
                fast.withUnsafeMutableBufferPointer { buf in
                    guard let base = buf.baseAddress else { return }
                    AemiKernels.xorMask4(base + offset, count: length, mask: mask, backend: .fastest)
                }
                #expect(
                    fast == Array(original[0 ..< (offset + length)]),
                    "involution length=\(length) offset=\(offset)"
                )
            }
        }
    }
}

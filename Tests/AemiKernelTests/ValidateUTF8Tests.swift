import AemiKernel
import AemiTestKit
import Testing

struct ValidateUTF8Tests {
    @Test func acceptsWellFormed() {
        let samples = [
            "", "a", "hello world",
            String(repeating: "x", count: 100),  // long all-ASCII (exercises the SIMD skip)
            "café résumé costs €1",
            "😀🎉 mixed 日本語 text long enough to cross several sixteen-byte chunks for sure"
        ]
        for s in samples {
            let bytes = Array(s.utf8)
            #expect(UTF8Validation.firstInvalidByte(bytes) == nil)
            #expect(UTF8Validation.firstInvalidByteScalar(bytes) == nil)
        }
    }

    @Test func detectsInvalidAtCorrectOffset() {
        #expect(UTF8Validation.firstInvalidByteScalar([0x80]) == 0)  // lone continuation
        #expect(UTF8Validation.firstInvalidByteScalar([0x61, 0x62, 0x63, 0xC2]) == 3)  // truncated 2-byte
        #expect(UTF8Validation.firstInvalidByteScalar([0xC0, 0x80]) == 0)  // overlong
        #expect(UTF8Validation.firstInvalidByteScalar([0xED, 0xA0, 0x80]) == 0)  // surrogate
        #expect(UTF8Validation.firstInvalidByteScalar([0xF4, 0x90, 0x80, 0x80]) == 0)  // > U+10FFFF
    }

    @Test func nonAsciiStraddlingChunkBoundary() {
        var bytes = [UInt8](repeating: UInt8(ascii: "a"), count: 15)
        bytes += Array("é".utf8)  // 2-byte sequence spanning the 16-byte chunk boundary
        bytes += [UInt8](repeating: UInt8(ascii: "b"), count: 40)
        #expect(UTF8Validation.firstInvalidByte(bytes) == nil)
        #expect(UTF8Validation.firstInvalidByte(bytes) == UTF8Validation.firstInvalidByteScalar(bytes))
    }

    /// The SIMD path must return the same offset (or nil) as the scalar reference for every input —
    /// valid mixed UTF-8 of varied length, with occasional byte corruption.
    @Test func simdMatchesScalarFuzzed() {
        var rng = SeededRNG(seed: 0xD1B5_4A32_D192_ED03)
        let pool: [UInt32] = [0x41, 0x7A, 0x20, 0x09, 0x00E9, 0x20AC, 0x65E5, 0x1F600]  // a z sp tab é € 日 😀
        var mismatches = 0
        for _ in 0 ..< 3000 {
            var bytes: [UInt8] = []
            for _ in 0 ..< rng.int(64) {
                bytes += Array(String(Unicode.Scalar(pool[rng.int(pool.count)]) ?? " ").utf8)
            }
            if rng.int(2) == 0, !bytes.isEmpty {
                for _ in 0 ... rng.int(3) { bytes[rng.int(bytes.count)] = UInt8(rng.int(256)) }
            }
            if UTF8Validation.firstInvalidByte(bytes) != UTF8Validation.firstInvalidByteScalar(bytes) {
                mismatches += 1
            }
        }
        #expect(mismatches == 0)
    }

    @Test func isValidConvenience() {
        #expect(UTF8Validation.firstInvalidByte(Array("ok ✓ string".utf8)) == nil)
    }

    /// A first chunk that is already non-ASCII trips the density probe into the scalar path; the SIMD
    /// entry point must still agree with the scalar reference, valid or corrupted.
    @Test func denseMultibyteAgreesWithScalar() {
        let dense = Array(String(repeating: "日", count: 40).utf8)  // all 3-byte sequences
        #expect(UTF8Validation.firstInvalidByte(dense) == nil)
        #expect(UTF8Validation.firstInvalidByte(dense) == UTF8Validation.firstInvalidByteScalar(dense))
        var bad = dense
        bad[7] = 0x00  // break a continuation byte
        #expect(UTF8Validation.firstInvalidByte(bad) != nil)
        #expect(UTF8Validation.firstInvalidByte(bad) == UTF8Validation.firstInvalidByteScalar(bad))
    }

    /// Inputs straddling the 16-byte SIMD threshold: 15 bytes uses scalar, 16 enters the vector path.
    @Test func straddlesSimdThreshold() {
        #expect(UTF8Validation.firstInvalidByte([UInt8](repeating: UInt8(ascii: "a"), count: 15)) == nil)
        #expect(UTF8Validation.firstInvalidByte([UInt8](repeating: UInt8(ascii: "a"), count: 16)) == nil)
        var fifteen = [UInt8](repeating: UInt8(ascii: "a"), count: 15)
        fifteen[14] = 0x80  // lone continuation at the end
        #expect(UTF8Validation.firstInvalidByte(fifteen) == 14)
    }
}

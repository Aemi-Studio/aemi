import AemiKernels
import AemiTestKit
import Testing

// Validation surface for the simdjson-style `firstInvalidUTF8` kernel. Two layers:
//   • ANCHORS — hand-verified valid/invalid inputs with KNOWN first-invalid offsets, checked on BOTH
//     backends. These pin the scalar oracle itself (so a "SIMD matches a wrong oracle" bug can't hide).
//   • DIFFERENTIAL — SIMD (`.fastest`) must equal the scalar oracle over 20k generated multibyte
//     buffers and every 16-byte block/tail boundary placement. A wrong classification-table entry
//     surfaces here as a mismatch.
struct AemiKernelsUTF8Tests {
    @Test func anchorCases() {
        let valid: [[UInt8]] = [
            Array("café résumé 日本語 😀".utf8),
            [], [0x41], [0xC2, 0x80], [0xDF, 0xBF], [0xE0, 0xA0, 0x80], [0xED, 0x9F, 0xBF],
            [0xEE, 0x80, 0x80], [0xEF, 0xBF, 0xBF], [0xF0, 0x90, 0x80, 0x80], [0xF4, 0x8F, 0xBF, 0xBF]
        ]
        for bytes in valid {
            #expect(AemiKernels.firstInvalidUTF8(bytes, backend: .fastest) == nil, "\(bytes)")
            #expect(AemiKernels.firstInvalidUTF8(bytes, backend: .scalar) == nil, "\(bytes)")
        }
        let invalid: [([UInt8], Int)] = [
            ([0x80], 0),  // lone continuation
            ([0xBF], 0),
            ([0xC0, 0x80], 0),  // overlong 2
            ([0xC1, 0xBF], 0),  // overlong 2 (U+007F)
            ([0xE0, 0x80, 0x80], 0),  // overlong 3
            ([0xF0, 0x80, 0x80, 0x80], 0),  // overlong 4
            ([0xED, 0xA0, 0x80], 0),  // surrogate U+D800
            ([0xED, 0xBF, 0xBF], 0),  // surrogate U+DFFF
            ([0xF4, 0x90, 0x80, 0x80], 0),  // > U+10FFFF
            ([0xF5, 0x80, 0x80, 0x80], 0),  // invalid lead
            ([0xC2, 0x41], 0),  // bad continuation
            ([0xE0, 0xA0], 0),  // truncated 3-byte
            ([0x41, 0xC2], 1),  // truncated at end
            ([0x61, 0x62, 0xED, 0xA0, 0x80], 2),  // surrogate after 2 ASCII
            ([0x41, 0x41, 0x41, 0xF0, 0x90], 3)  // truncated 4-byte after ASCII
        ]
        for (bytes, offset) in invalid {
            #expect(AemiKernels.firstInvalidUTF8(bytes, backend: .fastest) == offset, "\(bytes)")
            #expect(AemiKernels.firstInvalidUTF8(bytes, backend: .scalar) == offset, "\(bytes)")
        }
    }

    /// UTF-8 "units": valid 1–4 byte sequences + invalid fragments, concatenated into varied buffers.
    static let units: [[UInt8]] = {
        var out: [[UInt8]] = []
        let scalars: [UInt32] = [
            0x41, 0x7F, 0x80, 0x7FF, 0x800, 0xD7FF, 0xE000, 0xFFFF, 0x10000, 0x10FFFF, 0xE9, 0x20AC,
            0x65E5, 0x1F600
        ]
        for value in scalars {
            if let scalar = Unicode.Scalar(value) { out.append(Array(String(scalar).utf8)) }
        }
        out += [
            [0x80], [0xBF], [0xC0], [0xC1], [0xF5], [0xFF], [0xC2], [0xE0, 0x80], [0xED, 0xA0],
            [0xF0, 0x80], [0xE0, 0xA0], [0xF4, 0x90], [0x80, 0x80], [0xC2, 0x00], [0xF0, 0x90, 0x80]
        ]
        return out
    }()

    @Test func simdMatchesScalarExhaustive() {
        var rng = SeededRNG(seed: 0xF00D_CAFE_1234_5678)
        var mismatches = 0
        for _ in 0 ..< 20000 {
            var buffer: [UInt8] = []
            for _ in 0 ..< rng.int(12) { buffer += Self.units[rng.int(Self.units.count)] }
            if rng.int(3) == 0, !buffer.isEmpty { buffer[rng.int(buffer.count)] = UInt8(rng.int(256)) }
            if AemiKernels.firstInvalidUTF8(buffer, backend: .fastest)
                != AemiKernels.firstInvalidUTF8(buffer, backend: .scalar)
            {
                mismatches += 1
            }
        }
        #expect(mismatches == 0)
    }

    /// Place each unit at every offset around the 16/32-byte block and tail seams in an ASCII buffer.
    @Test func boundaryPlacement() {
        var mismatches = 0
        let placed: [[UInt8]] = [
            [0xC2, 0x80], [0xE0, 0xA0, 0x80], [0xF0, 0x90, 0x80, 0x80], [0xED, 0xA0, 0x80],
            [0xC0, 0x80], [0xE0, 0xA0], [0xF0, 0x90, 0x80], [0x80], [0xF4, 0x90, 0x80, 0x80]
        ]
        for unit in placed {
            for size in [0, 8, 14, 15, 16, 17, 30, 31, 32, 33, 48] {
                for offset in 0 ... size {
                    var buffer = [UInt8](repeating: UInt8(ascii: "a"), count: size)
                    buffer.insert(contentsOf: unit, at: offset)
                    if AemiKernels.firstInvalidUTF8(buffer, backend: .fastest)
                        != AemiKernels.firstInvalidUTF8(buffer, backend: .scalar)
                    {
                        mismatches += 1
                    }
                }
            }
        }
        #expect(mismatches == 0)
    }

    @Test func longMultibyteValidatesValid() {
        let bytes = Array(String(repeating: "日本語テキスト résumé café 😀🎉 ", count: 200).utf8)
        #expect(bytes.count > 4096)  // exercises many SIMD blocks
        #expect(AemiKernels.firstInvalidUTF8(bytes, backend: .fastest) == nil)
        #expect(AemiKernels.firstInvalidUTF8(bytes, backend: .scalar) == nil)
    }
}

import AemiKernels
import Testing

/// IEEE 802.3 / ISO-HDLC / gzip CRC-32 (RFC 1952 §8, reflected polynomial `0xEDB88320`, raw update).
/// `.fastest` (ARMv8 CRC32 on arm64, PCLMULQDQ 4-way folding on x86) must match `.scalar` (slicing-by-8)
/// and an independent bitwise reference across every length, alignment, and chunked streaming split.
struct AemiKernelsCRC32IEEETests {
    static func reference(_ crc: UInt32, _ bytes: ArraySlice<UInt8>) -> UInt32 {
        var crc = crc
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0 ..< 8 {
                crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xEDB8_8320 : 0)
            }
        }
        return crc
    }

    static func crc(_ seed: UInt32, _ bytes: ArraySlice<UInt8>, _ backend: AemiKernels.Backend) -> UInt32 {
        bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return seed }
            return AemiKernels.crc32IEEE(seed, base, count: buffer.count, backend: backend)
        }
    }

    @Test func rfc1952KnownVectors() {
        #expect(~Self.crc(~0, [][...], .fastest) == 0x0000_0000)
        #expect(~Self.crc(~0, Array("123456789".utf8)[...], .fastest) == 0xCBF4_3926)
        #expect(~Self.crc(~0, [UInt8](repeating: 0, count: 32)[...], .fastest) == 0x190A_55AD)
        #expect(~Self.crc(~0, [UInt8](repeating: 0xFF, count: 32)[...], .fastest) == 0xFF6C_AB0B)
    }

    @Test func everyBackendAgreesWithBitwiseReferenceAcrossLengthsAndAlignments() {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        let data = (0 ..< 5000)
            .map { _ -> UInt8 in
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return UInt8(truncatingIfNeeded: state >> 33)
            }
        for start in [0, 1, 3, 7] {
            for length in Array(0 ... 300) + [511, 512, 1023, 2048, 4095, 4096] {
                let slice = data[start ..< (start + length)]
                let seed = UInt32(truncatingIfNeeded: length &* 2_654_435_761)
                let expected = Self.reference(seed, slice)
                #expect(Self.crc(seed, slice, .fastest) == expected, "fastest length=\(length) start=\(start)")
                #expect(Self.crc(seed, slice, .scalar) == expected, "scalar length=\(length) start=\(start)")
            }
        }
    }

    @Test func streamingChunkedFoldMatchesOneShot() {
        let data = Array((0 ..< 1024).map { UInt8($0 & 0xFF) })
        let oneShot = ~Self.crc(~0, data[...], .fastest)
        var running: UInt32 = ~0
        for split in [0 ..< 1, 1 ..< 7, 7 ..< 70, 70 ..< 255, 255 ..< 513, 513 ..< 1024] {
            running = Self.crc(running, data[split], .fastest)
        }
        #expect(~running == oneShot)
    }
}

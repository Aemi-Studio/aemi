import AemiKernels
import Testing

// CRC-32C (Castagnoli, reflected, raw update: the caller chooses seed and final inversion). `.fastest` (the eight-lane
// PMULL fold on arm64, SSE4.2 `crc32` on x86-64) must equal `.scalar` and an independent bitwise reference at every
// length through the fold's tiers, from misaligned starts; RFC 3720 B.4 gives the published values.
struct AemiKernelsCRC32CTests {
    static func reference(_ crc: UInt32, _ bytes: ArraySlice<UInt8>) -> UInt32 {
        var crc = crc
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0 ..< 8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0x82F6_3B78 : 0) }
        }
        return crc
    }

    static func crc(_ seed: UInt32, _ bytes: ArraySlice<UInt8>, _ backend: AemiKernels.Backend) -> UInt32 {
        bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return seed }
            return AemiKernels.crc32c(seed, base, count: buffer.count, backend: backend)
        }
    }

    @Test func rfc3720Vectors() {
        // B.4: 32 zero bytes, 32 bytes of 0xFF, and 0...31; with seed ~0 and the result inverted.
        #expect(~Self.crc(~0, [UInt8](repeating: 0, count: 32)[...], .fastest) == 0x8A91_36AA)
        #expect(~Self.crc(~0, [UInt8](repeating: 0xFF, count: 32)[...], .fastest) == 0x62A8_AB43)
        #expect(~Self.crc(~0, Array(0 ..< 32)[...], .fastest) == 0x46DD_794E)
        #expect(~Self.crc(~0, Array("123456789".utf8)[...], .fastest) == 0xE306_9283)
    }

    @Test func everyBackendAgreesWithTheReferenceAtEveryLength() {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        let data = (0 ..< 9016)
            .map { _ -> UInt8 in
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return UInt8(truncatingIfNeeded: state >> 33)
            }
        for start in [0, 1, 3, 7] {
            for length in Array(0 ... 600) + [767, 768, 1023, 2047, 3071, 3072, 4064, 4096, 9000] {
                let slice = data[start ..< (start + length)]
                let seed = UInt32(truncatingIfNeeded: length &* 2_654_435_761)
                let expected = Self.reference(seed, slice)
                #expect(Self.crc(seed, slice, .fastest) == expected, "fastest, length \(length) at \(start)")
                #expect(Self.crc(seed, slice, .scalar) == expected, "scalar, length \(length) at \(start)")
            }
        }
    }

    /// The hybrid works in 4096-byte chunks, each from seed 0 and shifted into place: lengths on and around one and several
    /// chunks, with every remainder path after them (none, the fold, single words), from misaligned starts.
    @Test func chunkBoundariesAndSeveralChunks() {
        var state: UInt32 = 0x1234_5678
        let data = (0 ..< 70_000)
            .map { _ -> UInt8 in
                state = state &* 1_664_525 &+ 1_013_904_223
                return UInt8(truncatingIfNeeded: state >> 24)
            }
        for start in [0, 5] {
            for length in [
                4095, 4096, 4097, 4096 + 255, 4096 + 256, 8191, 8192, 8192 + 300, 12_288 + 7, 65_536, 65_536 + 4096 + 77
            ] {
                let slice = data[start ..< (start + length)]
                #expect(Self.crc(~0, slice, .fastest) == Self.reference(~0, slice), "length \(length) at \(start)")
                #expect(
                    Self.crc(0x0BAD_F00D, slice, .fastest) == Self.reference(0x0BAD_F00D, slice), "seeded, \(length)")
            }
        }
    }

    @Test func anEmptyBufferLeavesTheSeed() {
        #expect(Self.crc(0x1234_5678, [][...], .fastest) == 0x1234_5678)
    }
}

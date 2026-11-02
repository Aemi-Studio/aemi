import AemiKernel
import AemiTestKit
import Testing

/// Bulk hex against a naive reference: every length around the vector steps, both cases, a bad byte at every position, odd
/// lengths, buffers too small, and non-contiguous input (which is copied, then takes the same kernels).
struct HexBulkTests {
    private static let lower = Array("0123456789abcdef".utf8)
    private static let upper = Array("0123456789ABCDEF".utf8)

    private static func naive(_ bytes: [UInt8], uppercase: Bool) -> [UInt8] {
        let digits = uppercase ? upper : lower
        return bytes.flatMap { [digits[Int($0 >> 4)], digits[Int($0 & 15)]] }
    }

    @Test func knownVectors() throws {
        #expect(Hex.encodedString([]) == "")
        #expect(Hex.encodedString([0x00, 0x0F, 0xAB, 0xFF]) == "000fabff")
        #expect(Hex.encodedString([0xDE, 0xAD, 0xBE, 0xEF], uppercase: true) == "DEADBEEF")
        #expect(try Hex.decode("DeadBEEF") == [0xDE, 0xAD, 0xBE, 0xEF])
        #expect(try Hex.decode("") == [])
    }

    @Test func everyLengthMatchesTheReferenceAndRoundTrips() throws {
        var rng = SeededRNG(seed: Seed.named("hex.bulk.lengths"))
        for length in 0 ... 300 {
            let bytes = Base64Generators.randomBytes(length, &rng)
            for uppercase in [false, true] {
                let encoded = Hex.encode(bytes, uppercase: uppercase)
                #expect(encoded == Self.naive(bytes, uppercase: uppercase), "length \(length)")
                #expect(try Hex.decode(encoded) == bytes)
                #expect(try Hex.decode(NonContiguousBytes(storage: encoded)) == bytes)
            }
            // Mixed case decodes too.
            let mixed = Self.naive(bytes, uppercase: false).enumerated()
                .map { $0.offset % 3 == 0 ? Self.toUpper($0.element) : $0.element }
            #expect(try Hex.decode(mixed) == bytes)
        }
        let large = Base64Generators.randomBytes(1 << 20, &rng)
        #expect(try Hex.decode(Hex.encode(large)) == large)
    }

    private static func toUpper(_ byte: UInt8) -> UInt8 { byte >= 0x61 && byte <= 0x66 ? byte - 32 : byte }

    @Test func theFirstBadByteIsReportedWhereverItIs() {
        var rng = SeededRNG(seed: Seed.named("hex.bulk.bad"))
        let junk: [UInt8] = [
            UInt8(ascii: "g"), UInt8(ascii: "G"), 0x2F, 0x3A, 0x40, 0x60, 0x80, 0xFF, 0, 0x20, UInt8(ascii: "x")
        ]
        for length in [1, 2, 15, 16, 17, 31, 32, 33, 64, 100, 129] {
            let text = Self.naive(Base64Generators.randomBytes(length, &rng), uppercase: false)
            for position in 0 ..< text.count {
                var broken = text
                let bad = junk[(position + length) % junk.count]
                broken[position] = bad
                #expect(throws: Hex.DecodeError.invalidByte(bad, offset: position)) { try Hex.decode(broken) }
                // A second bad byte later never wins.
                if position + 3 < broken.count {
                    broken[position + 3] = UInt8(ascii: "z")
                    #expect(throws: Hex.DecodeError.invalidByte(bad, offset: position)) { try Hex.decode(broken) }
                }
            }
        }
    }

    @Test func oddLengthsAreRejectedAfterTheirBytesAreChecked() {
        #expect(throws: Hex.DecodeError.oddLength(3)) { try Hex.decode("abc") }
        #expect(throws: Hex.DecodeError.invalidByte(UInt8(ascii: "g"), offset: 2)) { try Hex.decode("abg") }
        #expect(throws: Hex.DecodeError.oddLength(65)) { try Hex.decode(String(repeating: "a", count: 65)) }
        #expect(throws: Hex.DecodeError.invalidByte(UInt8(ascii: " "), offset: 64)) {
            try Hex.decode(String(repeating: "a", count: 64) + " ")
        }
    }

    @Test func callerBuffersAreSizeChecked() throws {
        var out = [UInt8](repeating: 0, count: 7)
        let tooLong = Array("00".utf8) + Array(repeating: 0x30, count: 14)
        let results = out.withUnsafeMutableBufferPointer { buffer -> [Result<Int, any Error>] in
            [
                Result { try Hex.encode([1, 2, 3, 4], into: buffer) },
                Result { try Hex.encode([1, 2, 3], into: buffer) },
                Result { try Hex.decode(tooLong, into: buffer) },
                Result { try Hex.decode(Array("0102ff".utf8), into: buffer) }
            ]
        }
        #expect(throws: Hex.EncodeError.outputBufferTooSmall(required: 8)) { try results[0].get() }
        #expect(try results[1].get() == 6)
        #expect(throws: Hex.DecodeError.outputBufferTooSmall(required: 8)) { try results[2].get() }
        #expect(try results[3].get() == 3)
        #expect(out[0 ..< 3] == [1, 2, 0xFF])
    }
}

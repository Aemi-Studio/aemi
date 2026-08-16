import AemiKernel
import Testing

struct Base64Tests {
    private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }
    private func string(_ b: [UInt8]) -> String { String(decoding: b, as: UTF8.self) }

    // RFC 4648 §10 test vectors (standard alphabet, padded).
    @Test func rfc4648Vectors() {
        #expect(Base64.encodedString(bytes("")) == "")
        #expect(Base64.encodedString(bytes("f")) == "Zg==")
        #expect(Base64.encodedString(bytes("fo")) == "Zm8=")
        #expect(Base64.encodedString(bytes("foo")) == "Zm9v")
        #expect(Base64.encodedString(bytes("foob")) == "Zm9vYg==")
        #expect(Base64.encodedString(bytes("fooba")) == "Zm9vYmE=")
        #expect(Base64.encodedString(bytes("foobar")) == "Zm9vYmFy")
    }

    @Test func decodesRfc4648Vectors() {
        #expect(Base64.decode(bytes("")) == bytes(""))
        #expect(Base64.decode(bytes("Zg==")).map(string) == "f")
        #expect(Base64.decode(bytes("Zm8=")).map(string) == "fo")
        #expect(Base64.decode(bytes("Zm9v")).map(string) == "foo")
        #expect(Base64.decode(bytes("Zm9vYg==")).map(string) == "foob")
        #expect(Base64.decode(bytes("Zm9vYmE=")).map(string) == "fooba")
        #expect(Base64.decode(bytes("Zm9vYmFy")).map(string) == "foobar")
    }

    @Test func unpaddedRoundTrips() {
        #expect(string(Base64.encode(bytes("f"), padding: false)) == "Zg")
        #expect(string(Base64.encode(bytes("fo"), padding: false)) == "Zm8")
        // Decode accepts input with or without padding.
        #expect(Base64.decode(bytes("Zg")).map(string) == "f")
        #expect(Base64.decode(bytes("Zm8")).map(string) == "fo")
    }

    @Test func urlSafeAlphabetDiffersOnlyInTwoChars() {
        // 0xFF 0xFF 0xFF -> all sextets = 63 -> "////" (standard) / "____" (url-safe).
        let triple: [UInt8] = [0xFF, 0xFF, 0xFF]
        #expect(string(Base64.encode(triple, alphabet: .standard)) == "////")
        #expect(string(Base64.encode(triple, alphabet: .urlSafe)) == "____")
        #expect(Base64.decode(bytes("////"), alphabet: .standard) == triple)
        #expect(Base64.decode(bytes("____"), alphabet: .urlSafe) == triple)
        // Cross-alphabet input is rejected (no '/' in the url-safe alphabet).
        #expect(Base64.decode(bytes("////"), alphabet: .urlSafe) == nil)
    }

    @Test func roundTripsEveryByteValueBothAlphabets() {
        let all = (0 ... 255).map { UInt8($0) }
        for alphabet in [Base64.Alphabet.standard, .urlSafe] {
            for padding in [true, false] {
                let encoded = Base64.encode(all, alphabet: alphabet, padding: padding)
                #expect(Base64.decode(encoded, alphabet: alphabet) == all)
            }
        }
    }

    @Test func decodeRejectsMalformedInput() {
        #expect(Base64.decode(bytes("Zg$=")) == nil)  // char outside the alphabet
        #expect(Base64.decode(bytes("Zm9vY")) == nil)  // lone trailing sextet (impossible length)
        #expect(Base64.decode(bytes("Zg==X")) == nil)  // data after padding
        #expect(Base64.decode(bytes("-_"), alphabet: .standard) == nil)  // url-safe chars under standard
    }

    @Test func encodesKnownSha256DigestLikeSRI() {
        // SHA-256("") → this digest; its standard-padded base64 is the exact payload ADHTMLSRI embeds
        // in a `sha256-…` token. Anchors AemiKernel.Base64 to the byte-identical output the SRI refactor
        // (which swapped a local encoder for this one) now depends on.
        let emptyShaDigest: [UInt8] = [
            0xE3, 0xB0, 0xC4, 0x42, 0x98, 0xFC, 0x1C, 0x14, 0x9A, 0xFB, 0xF4, 0xC8, 0x99, 0x6F, 0xB9, 0x24,
            0x27, 0xAE, 0x41, 0xE4, 0x64, 0x9B, 0x93, 0x4C, 0xA4, 0x95, 0x99, 0x1B, 0x78, 0x52, 0xB8, 0x55
        ]
        #expect(Base64.encodedString(emptyShaDigest) == "47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=")
    }

    @Test func sriDigestSizing() {
        // A 32-byte SHA-256 digest base64-encodes to 44 chars (43 + one '='), the SRI payload length.
        let digest = [UInt8](repeating: 0, count: 32)
        let encoded = Base64.encodedString(digest)
        #expect(encoded.count == 44)
        #expect(Base64.decode(bytes(encoded)) == digest)
    }
}

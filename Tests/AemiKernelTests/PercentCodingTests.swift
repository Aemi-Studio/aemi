import AemiKernel
import Testing

struct PercentCodingTests {
    private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }
    private func string(_ b: [UInt8]) -> String { String(decoding: b, as: UTF8.self) }

    @Test func encodesUnreservedVerbatimAndEscapesTheRest() {
        #expect(string(PercentCoding.encode(bytes("abcXYZ012-._~"))) == "abcXYZ012-._~")
        #expect(string(PercentCoding.encode(bytes("a b/c?"))) == "a%20b%2Fc%3F")
    }

    @Test func escapeHexIsUppercase() {
        // RFC 3986 §2.1 recommends uppercase hex in percent-encodings.
        #expect(string(PercentCoding.encode([0xAB, 0x0F])) == "%AB%0F")
    }

    @Test func encodeHonorsCustomAllowedSet() {
        #expect(PercentCoding.encode(bytes("a b/c"), allowed: { _ in true }) == bytes("a b/c"))
        #expect(string(PercentCoding.encode(bytes("ab"), allowed: { _ in false })) == "%61%62")
    }

    @Test func decodesValidTriplesAnyHexCase() {
        #expect(PercentCoding.decode(bytes("%41%2f%2F")) == bytes("A//"))
        #expect(PercentCoding.decode(bytes("plain text")) == bytes("plain text"))
    }

    @Test func decodeRejectsMalformedEscapes() {
        #expect(PercentCoding.decode(bytes("%G0")) == nil)  // non-hex digit
        #expect(PercentCoding.decode(bytes("%")) == nil)  // truncated, no digits
        #expect(PercentCoding.decode(bytes("%A")) == nil)  // truncated, one digit
        #expect(PercentCoding.decode(bytes("ok%2")) == nil)  // truncated mid-string
    }

    @Test func roundTripsEveryByteValue() {
        let all = (0 ... 255).map { UInt8($0) }
        #expect(PercentCoding.decode(PercentCoding.encode(all)) == all)
    }

    @Test func plusIsLeftLiteral() {
        // RFC 3986 percent-decoding does not map '+' to space; that is the form-urlencoded rule.
        #expect(PercentCoding.decode(bytes("a+b")) == bytes("a+b"))
    }

    @Test func decodeFormMapsPlusToSpace() {
        // application/x-www-form-urlencoded: a literal '+' becomes a space, but an escaped %2B stays
        // a literal '+'. Triples decode as usual.
        #expect(PercentCoding.decodeForm(bytes("a+b")) == bytes("a b"))
        #expect(PercentCoding.decodeForm(bytes("a%2Bb")) == bytes("a+b"))
        #expect(PercentCoding.decodeForm(bytes("x+y%20z")) == bytes("x y z"))
        // Still rejects malformed escapes (the no-trap nil contract the safe call site relies on).
        #expect(PercentCoding.decodeForm(bytes("%G0")) == nil)
        #expect(PercentCoding.decodeForm(bytes("ok%2")) == nil)
        // Regression guard: plain decode keeps '+' literal even after the shared core refactor.
        #expect(PercentCoding.decode(bytes("a+b")) == bytes("a+b"))
    }
}

import AemiKernel
import Testing

struct HexTests {
    @Test func decodesDigits() {
        // A typed (input, expected) table looped once, rather than eight separate `#expect`s — each
        // inline `Hex.value(UInt8(ascii:)) == <literal>/nil` makes the type-checker re-solve the
        // optional-comparison overload, and eight of them pushed this body past the 100ms budget
        // (hard error under the test settings). The explicit `[(UInt8, UInt8?)]` collapses it to one.
        let cases: [(input: UInt8, expected: UInt8?)] = [
            (UInt8(ascii: "0"), 0), (UInt8(ascii: "9"), 9),
            (UInt8(ascii: "a"), 10), (UInt8(ascii: "f"), 15),
            (UInt8(ascii: "A"), 10), (UInt8(ascii: "F"), 15),
            (UInt8(ascii: "g"), nil), (UInt8(ascii: " "), nil)
        ]
        for (input, expected) in cases {
            #expect(Hex.value(input) == expected)
        }
    }

    @Test func encodesLowercase() {
        #expect(Hex.digit(0) == UInt8(ascii: "0"))
        #expect(Hex.digit(9) == UInt8(ascii: "9"))
        #expect(Hex.digit(10) == UInt8(ascii: "a"))
        #expect(Hex.digit(15) == UInt8(ascii: "f"))
    }

    @Test func roundTrip() {
        for v: UInt8 in 0 ... 15 { #expect(Hex.value(Hex.digit(v)) == v) }
    }
}

struct ASCIITests {
    @Test func byteClassification() {
        #expect(ASCII.isDigit(UInt8(ascii: "5")))
        #expect(!ASCII.isDigit(UInt8(ascii: "a")))
        #expect(ASCII.isAlpha(UInt8(ascii: "z")))
        #expect(ASCII.isAlpha(UInt8(ascii: "A")))
        #expect(ASCII.isAlphanumeric(UInt8(ascii: "0")))
        #expect(ASCII.isHexDigit(UInt8(ascii: "F")))
        #expect(!ASCII.isHexDigit(UInt8(ascii: "g")))
        #expect(ASCII.isSubDelimiter(UInt8(ascii: "&")))
        #expect(!ASCII.isSubDelimiter(UInt8(ascii: "@")))
    }

    @Test func characterClassification() {
        #expect(Character("a").isASCIIAlpha)
        #expect(Character("Z").isASCIIAlpha)
        #expect(Character("7").isASCIIDigit)
        #expect(Character("c").isASCIIHexDigit)
        #expect(!Character("x").isASCIIHexDigit)
        #expect(Character("=").isSubDelimiter)
    }
}

struct UTF8ValidationTests {
    private func seqLen(_ bytes: [UInt8]) -> Int? {
        bytes.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return nil }
            return UTF8Validation.sequenceLength(base, 0, buf.count)
        }
    }

    @Test func leadLengths() {
        #expect(UTF8Validation.leadLength(0xC2) == 2)
        #expect(UTF8Validation.leadLength(0xE2) == 3)
        #expect(UTF8Validation.leadLength(0xF0) == 4)
        #expect(UTF8Validation.leadLength(0x80) == nil)
        #expect(UTF8Validation.leadLength(0xF8) == nil)
    }

    @Test func acceptsWellFormed() {
        #expect(seqLen([0xC2, 0xA9]) == 2)  // ©
        #expect(seqLen([0xE2, 0x82, 0xAC]) == 3)  // €
        #expect(seqLen([0xF0, 0x9F, 0x98, 0x80]) == 4)  // 😀
    }

    @Test func rejectsMalformed() {
        #expect(seqLen([0xC0, 0x80]) == nil)  // overlong NUL
        #expect(seqLen([0xE2, 0x28, 0xA1]) == nil)  // bad continuation
        #expect(seqLen([0xED, 0xA0, 0x80]) == nil)  // surrogate U+D800
        #expect(seqLen([0xC2]) == nil)  // truncated
        #expect(seqLen([0xF4, 0x90, 0x80, 0x80]) == nil)  // > U+10FFFF
    }
}

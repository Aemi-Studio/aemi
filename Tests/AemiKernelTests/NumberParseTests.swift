import AemiKernel
import Testing

struct NumberParseTests {
    private func utf8(_ s: String) -> [UInt8] { Array(s.utf8) }

    @Test func doublePrefixParsesCommonForms() {
        #expect(NumberParse.doublePrefix(utf8("3.14")) == 3.14)
        #expect(NumberParse.doublePrefix(utf8("-2")) == -2)
        #expect(NumberParse.doublePrefix(utf8("+5")) == 5)
        #expect(NumberParse.doublePrefix(utf8("0.65")) == 0.65)
        #expect(NumberParse.doublePrefix(utf8(".5")) == 0.5)
        #expect(NumberParse.doublePrefix(utf8("5.")) == 5.0)
        #expect(NumberParse.doublePrefix(utf8("1e3")) == 1000)
        #expect(NumberParse.doublePrefix(utf8("1.5e-2")) == 0.015)
        #expect(NumberParse.doublePrefix(utf8("-2.5e-1")) == -0.25)
    }

    @Test func doublePrefixSkipsLeadingWhitespaceAndTrailingGarbage() {
        #expect(NumberParse.doublePrefix(utf8("  0.65xyz")) == 0.65)
        #expect(NumberParse.doublePrefix(utf8("\t-.5e1 ")) == -5.0)
        #expect(NumberParse.doublePrefix(utf8("200ms")) == 200)
        // A dangling '.'/'e' with no digits is dropped, not an error.
        #expect(NumberParse.doublePrefix(utf8("1e")) == 1)
        #expect(NumberParse.doublePrefix(utf8("1ex")) == 1)
    }

    @Test func doublePrefixRejectsNonNumbers() {
        #expect(NumberParse.doublePrefix(utf8("")) == nil)
        #expect(NumberParse.doublePrefix(utf8("abc")) == nil)
        #expect(NumberParse.doublePrefix(utf8("+")) == nil)
        #expect(NumberParse.doublePrefix(utf8(".")) == nil)
        #expect(NumberParse.doublePrefix(utf8("   ")) == nil)
    }

    @Test func doublePrefixMatchesStdlibAcrossTheFastPathAndFallback() {
        // The fast path must be byte-identical to the stdlib's correctly-rounded parser, and the
        // over-long fallback must agree too. (`9007199254740993` = 2^53+1 forces the fallback.)
        let cases = [
            "0.1", "0.2", "0.3", "1.1", "123.456", "0.7", "1e10", "9.99e-7", "42", "1000000",
            "9007199254740993", "123456789012345678901234567890", "1.7976931348623157e308"
        ]
        for s in cases {
            #expect(NumberParse.doublePrefix(utf8(s)) == Double(s), "mismatch for \(s)")
        }
    }

    @Test func intPrefixParsesAndBounds() {
        #expect(NumberParse.intPrefix(utf8("42")) == 42)
        #expect(NumberParse.intPrefix(utf8("-7")) == -7)
        #expect(NumberParse.intPrefix(utf8("+9")) == 9)
        #expect(NumberParse.intPrefix(utf8("10px")) == 10)
        #expect(NumberParse.intPrefix(utf8("  123 ")) == 123)
        #expect(NumberParse.intPrefix(utf8("ff"), radix: 16) == 255)
        #expect(NumberParse.intPrefix(utf8("z"), radix: 36) == 35)
        #expect(NumberParse.intPrefix(utf8("abc")) == nil)
        #expect(NumberParse.intPrefix(utf8("")) == nil)
    }

    @Test func intPrefixHandlesOverflowAndIntMin() {
        #expect(NumberParse.intPrefix(utf8("-9223372036854775808")) == Int.min)
        #expect(NumberParse.intPrefix(utf8("9223372036854775807")) == Int.max)
        #expect(NumberParse.intPrefix(utf8("9223372036854775808")) == nil)  // +|Int.min| not representable
        #expect(NumberParse.intPrefix(utf8("99999999999999999999")) == nil)  // overflow
    }

    @Test func parsesAppleDocsEnvConfigValues() {
        // The real apple-docs env-config strings the ADSearchCascade/ADSemantic parsers (now
        // delegating here) read — MMR lambda (parseFloat, clamped 0...1) and shortlist/topK/year
        // (parseInt). The A3 gate: these parse identically to the prior hand-rolled scalar loops.
        #expect(NumberParse.doublePrefix(utf8("0.7")) == 0.7)  // APPLE_DOCS_MMR_LAMBDA default
        #expect(NumberParse.doublePrefix(utf8("0.5")) == 0.5)
        #expect(NumberParse.doublePrefix(utf8("1")) == 1.0)
        #expect(NumberParse.doublePrefix(utf8("0")) == 0.0)
        #expect(NumberParse.intPrefix(utf8("200")) == 200)  // APPLE_DOCS_SEMANTIC_SHORTLIST default
        #expect(NumberParse.intPrefix(utf8("16")) == 16)  // shortlist clamp lower bound
        #expect(NumberParse.intPrefix(utf8("5000")) == 5000)  // shortlist clamp upper bound
        #expect(NumberParse.intPrefix(utf8("2024")) == 2024)  // year filter
    }
}

struct DecimalFloatTests {
    @Test func doubleFastPathDomain() {
        #expect(DecimalFloat.double(significand: 5, exponent: -1, negative: false) == 0.5)
        #expect(DecimalFloat.double(significand: 12345, exponent: 0, negative: true) == -12345)
        #expect(DecimalFloat.double(significand: 1, exponent: 22, negative: false) == 1e22)
        // Outside the exact domain → nil (caller falls back).
        #expect(DecimalFloat.double(significand: 1, exponent: 23, negative: false) == nil)
        #expect(DecimalFloat.double(significand: (1 << 53) + 1, exponent: 0, negative: false) == nil)
    }

    @Test func floatFastPathDomain() {
        #expect(DecimalFloat.float(significand: 5, exponent: -1, negative: false) == Float(0.5))
        #expect(DecimalFloat.float(significand: 1, exponent: 10, negative: false) == Float(1e10))
        #expect(DecimalFloat.float(significand: 1, exponent: 11, negative: false) == nil)
        #expect(DecimalFloat.float(significand: (1 << 24) + 1, exponent: 0, negative: false) == nil)
    }
}

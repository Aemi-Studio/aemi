import AemiKernel
import AemiTestKit
import Testing

/// Correctness gate for `DecimalFloat.eiselLemire`. The algorithm's contract is that whenever it returns
/// a non-nil result, that result is *bit-identical* to the standard library's correctly-rounded
/// `Double(_:)` parse of the exact decimal `significand·10^exponent`; when it cannot prove correct
/// rounding it returns nil and the caller falls back to `Double(_:)`. So the complete correctness oracle
/// is: for every input, `eiselLemire(...) ∈ { nil, Double(theExactString) }`. Any other value is a bug.
/// A table or algorithm error can therefore only surface as a bit-pattern mismatch here — never as a
/// silently wrong parse in production, since the same non-nil/nil split feeds the stdlib fallback.
struct EiselLemireTests {
    /// Returns nil on agreement; otherwise a human-readable mismatch (so `#expect` prints the case).
    private func mismatch(_ sig: UInt64, _ exp: Int, _ neg: Bool) -> String? {
        guard let el = DecimalFloat.eiselLemire(significand: sig, exponent: exp, negative: neg) else {
            return nil  // bailed → the stdlib fallback covers it; not a correctness failure
        }
        let s = (neg ? "-" : "") + "\(sig)e\(exp)"
        guard let ref = Double(s) else { return "stdlib rejected \(s)" }
        if el.bitPattern != ref.bitPattern {
            return "\(s): el=\(el) (0x\(String(el.bitPattern, radix: 16))) ref=\(ref) "
                + "(0x\(String(ref.bitPattern, radix: 16)))"
        }
        return nil
    }

    @Test func matchesStdlibOnKnownHardCases() {
        // The classic hard-to-round / boundary vectors (David Gay, Vern Paxson, the "PHP 2.2250738…e-308"
        // denial-of-service case, ties-to-even at 2^53). Each is ≤ 19 significant digits, so Eisel–Lemire
        // is actually exercised (not short-circuited by the > 19-digit guard).
        let cases: [(UInt64, Int, Bool)] = [
            (9_007_199_254_740_992, 0, false),  // 2^53
            (9_007_199_254_740_993, 0, false),  // 2^53 + 1 → ties to even (…992)
            (9_007_199_254_740_995, 0, false),  // → …996
            (9_223_372_036_854_775_807, 0, false),  // ~2^63
            (9_223_372_036_854_775_807, 0, true),
            (1, 22, false), (1, 23, false), (1, 300, false), (1, -300, false),
            (1, 308, false), (1, -308, false), (2, -308, false),
            (17_976_931_348_623_157, 292, false),  // Double.max: 1.7976931348623157e308
            (22_250_738_585_072_014, -324, false),  // min normal: 2.2250738585072014e-308
            (22_250_738_585_072_011, -324, false),  // the famous subnormal-boundary case
            (10_000_000_000_000_000_000, 0, false),  // 1e19 (20 digits would overflow; this is the boundary)
            (9_999_999_999_999_999_999, 0, false),  // 19 nines
            (9_999_999_999_999_999_999, -19, false),  // ≈ 1.0 from the other side
            (5_000_000_000_000_000, -16, false), (5_000_000_000_000_001, -16, false),
            (0, 100, false), (0, -100, true)  // ±0 regardless of exponent
        ]
        for (sig, exp, neg) in cases {
            #expect(mismatch(sig, exp, neg) == nil)
        }
    }

    @Test func endToEndParsersMatchStdlib() {
        // The wired paths (`NumberParse.doublePrefix`, and via it the ADJSON scanner that shares
        // `DecimalFloat.eiselLemire`) must round every literal exactly as `Double(_:)` — across the
        // Clinger domain, the Eisel–Lemire domain, and the > 19-digit stdlib fallback.
        let strings = [
            "0.1", "0.2", "0.3", "1.1", "123.456", "1e23", "1e-23", "1.1e300", "9.99e-7",
            "2.2250738585072011e-308", "2.2250738585072012e-308", "2.2250738585072014e-308",
            "1.7976931348623157e308", "4.9406564584124654e-324", "1.0000000000000002",
            "0.5000000000000001", "9007199254740993", "123456789012345678", "12345678901234567890",
            // > 19-digit hard-to-round monsters that must fall through to the correct stdlib parse:
            "123456789012345678901234567890", "9007199254740993.0000000000000001",
            "2.47032822920623272e-308"
        ]
        for s in strings {
            #expect(NumberParse.doublePrefix(Array(s.utf8)) == Double(s), "mismatch for \(s)")
        }
    }

    /// Every one of the 696 table entries (exp10 ∈ [-348, 347]) must be individually correct — sweep the
    /// full exponent range against several high-entropy significands so no single entry can be wrong
    /// without a failure here.
    @Test func everyTableEntryIsCorrect() {
        let sigs: [UInt64] = [
            1, 2, 3, 9, 10, 99,
            1_234_567_890_123_456_789, 9_999_999_999_999_999_999, 5_000_000_000_000_000_000,
            7_071_067_811_865_475_244, 3_141_592_653_589_793_238, 2_718_281_828_459_045_235
        ]
        var mismatches = 0
        for exp in (-348) ... 347 {
            for sig in sigs {
                if mismatch(sig, exp, false) != nil { mismatches += 1 }
                if mismatch(sig, exp, true) != nil { mismatches += 1 }
            }
        }
        #expect(mismatches == 0)
    }

    /// Randomized differential fuzz: half a million (significand ≤ 19 digits, exponent, sign) triples,
    /// each compared bit-for-bit against `Double(_:)`. Also asserts Eisel–Lemire actually *resolves* the
    /// large majority (so the oracle isn't passing vacuously by always bailing to the fallback).
    @Test func randomizedDifferentialFuzz() {
        var rng = SeededRNG(seed: 0x5E15_E1E3_D0AB_1E77)
        let iterations = 500_000
        var mismatches = 0
        var resolved = 0
        var firstFailure = ""
        for _ in 0 ..< iterations {
            let sig = UInt64.random(in: 0 ... 9_999_999_999_999_999_999, using: &rng)
            let exp = Int.random(in: -330 ... 308, using: &rng)
            let neg = Bool.random(using: &rng)
            if DecimalFloat.eiselLemire(significand: sig, exponent: exp, negative: neg) != nil {
                resolved += 1
            }
            if let m = mismatch(sig, exp, neg) {
                mismatches += 1
                if firstFailure.isEmpty { firstFailure = m }
            }
        }
        #expect(mismatches == 0, "first mismatch: \(firstFailure)")
        // Over this exponent range the vast majority of values are finite normals Eisel–Lemire resolves.
        #expect(resolved > iterations / 2, "Eisel–Lemire resolved only \(resolved)/\(iterations)")
    }

    /// Round-trip: random finite doubles → shortest decimal → parse. The parsed value must be the
    /// original bit-for-bit (shortest formatting + correct parsing is an exact round-trip).
    @Test func roundTripsRandomDoubles() {
        var rng = SeededRNG(seed: 0xD0B1_E77E_15E1_5E1E)
        var mismatches = 0
        for _ in 0 ..< 200_000 {
            // Draw a random finite double from a wide exponent range via raw bit patterns.
            let bits = UInt64.random(in: 0 ... 0x7FEF_FFFF_FFFF_FFFF, using: &rng)  // sign 0, exp < 0x7FF
            let d = Double(bitPattern: bits)
            let s = "\(d)"  // Swift's shortest round-tripping representation
            if let parsed = NumberParse.doublePrefix(Array(s.utf8)), parsed.bitPattern == d.bitPattern {
                continue
            }
            mismatches += 1
        }
        #expect(mismatches == 0)
    }
}

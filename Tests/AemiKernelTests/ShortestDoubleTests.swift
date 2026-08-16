import AemiKernel
import AemiTestKit
import Testing

/// Correctness gate for `DecimalFloat.shortestDouble` (the Ryu shortest-float formatter). The formatter
/// replaces the current `Double.description` + re-parse path, and ADJSON has byte-identical JS-parity
/// contracts, so the bar is: for every finite `v`, `shortestDouble(v)` must (a) round-trip — reconstruct
/// exactly `v` bit-for-bit — and (b) produce the SAME significant digits as `Double.description` (Swift's
/// own correctly-rounded shortest form). Together those force the emitted `(negative, digits, pointPos)`
/// to be identical to the old path, hence byte-identical output. There is no fallback here, so this
/// gate is the whole safety net.
struct ShortestDoubleTests {
    /// The bare significant digits of a decimal string: drop sign, `.`, any `e±NN`, and leading/trailing
    /// zeros — the shortest-digit core `Double.description` and `shortestDouble` must agree on.
    private func significantDigits(of s: String) -> String {
        var digits = ""
        for ch in s {
            if ch == "e" || ch == "E" { break }
            if ch.isNumber { digits.append(ch) }
        }
        var d = Substring(digits)
        while d.first == "0" { d = d.dropFirst() }
        while d.last == "0" { d = d.dropLast() }
        return String(d)
    }

    /// nil on agreement; else a description of the disagreement.
    private func mismatch(_ v: Double) -> String? {
        let (neg, sig, exp) = DecimalFloat.shortestDouble(v)
        // (a) round-trip, bit-for-bit.
        let s = (neg ? "-" : "") + "\(sig)e\(exp)"
        guard let back = Double(s), back.bitPattern == v.bitPattern else {
            return "\(v): shortest=\(s) did not round-trip (back=\(Double(s).map { "\($0)" } ?? "nil"))"
        }
        // (b) same significant digits as Double.description.
        let ref = significantDigits(of: v.description)
        let ours = sig == 0 ? "" : String(sig)
        if ref != ours {
            return "\(v): digits ours=\(ours) ref=\(ref) (desc=\(v.description))"
        }
        return nil
    }

    @Test func matchesDescriptionOnKnownCases() {
        let cases: [Double] = [
            0.0, -0.0, 1.0, -1.0, 2.0, 0.5, 0.1, 0.2, 0.3, 0.30000000000000004, 100.0, 1234.5,
            1e20, 1e21, 1e22, 1e23, 1e-6, 1e-7, 123.456, 9_007_199_254_740_992, 9_007_199_254_740_994,
            .pi, -.pi, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, .leastNormalMagnitude,
            .leastNonzeroMagnitude, 4.9406564584124654e-324, 2.2250738585072014e-308,
            1.7976931348623157e308, 3.141592653589793, 2.718281828459045, 6.022e23, 1.602176634e-19
        ]
        for v in cases {
            #expect(mismatch(v) == nil)
        }
    }

    /// Sweep every biased exponent with a handful of mantissas — cheap coverage of the full magnitude
    /// range and both the `e2 >= 0` and `e2 < 0` branches (incl. subnormals at exponent 0).
    @Test func sweepsExponentRange() {
        let mantissas: [UInt64] = [
            0, 1, 2, 0x000F_FFFF_FFFF_FFFF, 0x0008_0000_0000_0000, 0x000A_AAAA_AAAA_AAAA,
            0x0005_5555_5555_5555, 0x0001_2345_6789_ABCD
        ]
        var mismatches = 0
        for e in 0 ... 0x7FE {
            for m in mantissas {
                let bits = (UInt64(e) << 52) | m
                if mismatch(Double(bitPattern: bits)) != nil { mismatches += 1 }
                if mismatch(Double(bitPattern: bits | (1 << 63))) != nil { mismatches += 1 }  // negative
            }
        }
        #expect(mismatches == 0)
    }

    /// Randomized differential fuzz over arbitrary finite doubles (random bit patterns), each checked for
    /// round-trip + digit parity with `Double.description`.
    @Test func randomizedDifferentialFuzz() {
        var rng = SeededRNG(seed: 0x0DDB_A11E_D06F_00D5)
        let iterations = 1_000_000
        var mismatches = 0
        var firstFailure = ""
        for _ in 0 ..< iterations {
            // Any finite double: sign|exp|mantissa with exp in [0, 0x7FE].
            let sign = UInt64.random(in: 0 ... 1, using: &rng) << 63
            let exp = UInt64.random(in: 0 ... 0x7FE, using: &rng) << 52
            let mant = UInt64.random(in: 0 ... 0x000F_FFFF_FFFF_FFFF, using: &rng)
            let v = Double(bitPattern: sign | exp | mant)
            if let m = mismatch(v) {
                mismatches += 1
                if firstFailure.isEmpty { firstFailure = m }
            }
        }
        #expect(mismatches == 0, "first: \(firstFailure)")
    }
}

/// Decimal-significand → binary-float assembly: the Clinger fast path, shared by every number parser in
/// the family. A byte scanner accumulates a decimal significand and a power-of-ten exponent, then hands
/// them here. When the significand is exact in the target type (`≤ 2^53` for `Double`, `≤ 2^24` for
/// `Float`) and the exponent keeps the power-of-ten table exact (`±22` / `±10`), a single IEEE
/// multiply or divide is correctly rounded — bit-identical to the standard library's string parser — so
/// the common case never builds a `String`. Outside that proven domain these return `nil`, and the
/// caller falls back to the correctly-rounded stdlib parser.
///
/// Consolidates the duplicate `pow10` / `pow10Float` tables and Clinger fast paths that lived in
/// ADJSON's `JSONNumber` and in `AemiKernel.NumberParse`. `@inlinable @inline(__always)` so a hot scanner
/// (ADJSON's tape number path) inlines the assembly with zero call overhead.
public enum DecimalFloat {
    /// 10^0 … 10^22, each exact in `Double`: 10^22 = 5^22 · 2^22 with 5^22 < 2^53, while 10^23 is the
    /// first power of ten that is not exactly representable — which fixes the `±22` fast-path bound.
    public static let pow10: [Double] = [
        1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11,
        1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22
    ]

    /// 10^0 … 10^10, each exact in `Float`: 5^10 = 9_765_625 < 2^24, while 10^11 (5^11 = 48_828_125 >
    /// 2^24) is the first that is not — which fixes the `±10` fast-path bound.
    public static let pow10Float: [Float] = [
        1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10
    ]

    /// `significand · 10^exponent` as a correctly-rounded `Double`, or `nil` when outside the exact
    /// fast-path domain (`significand > 2^53` or `|exponent| > 22`). `negative` applies the sign.
    @inlinable @inline(__always)
    public static func double(significand: UInt64, exponent: Int, negative: Bool) -> Double? {
        guard significand <= (1 << 53), exponent >= -22, exponent <= 22 else { return nil }
        var value = Double(significand)
        if exponent > 0 {
            value *= pow10[exponent]
        } else if exponent < 0 {
            value /= pow10[-exponent]
        }
        return negative ? -value : value
    }

    /// `significand · 10^exponent` as a correctly-rounded `Float`, or `nil` when outside the exact
    /// fast-path domain (`significand > 2^24` or `|exponent| > 10`). `negative` applies the sign.
    /// Parsing straight to `Float` (rather than `Float(parseDouble(...))`) avoids double-rounding.
    @inlinable @inline(__always)
    public static func float(significand: UInt32, exponent: Int, negative: Bool) -> Float? {
        guard significand <= (1 << 24), exponent >= -10, exponent <= 10 else { return nil }
        var value = Float(significand)
        if exponent > 0 {
            value *= pow10Float[exponent]
        } else if exponent < 0 {
            value /= pow10Float[-exponent]
        }
        return negative ? -value : value
    }
}

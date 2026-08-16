/// Lenient UTF-8 scalar extraction — the permissive counterpart to ``UTF8Validation``.
///
/// Where ``UTF8Validation`` rejects malformed input (overlong forms, surrogates, truncation),
/// this never fails: a malformed or truncated sequence yields `(0xFFFD, 1)` so a caller that
/// already knows its input is well-formed — or that wants JavaScript-style permissive decoding —
/// can advance one scalar at a time without error handling. It decodes the raw bits only; it does
/// NOT check for overlong encodings, surrogates, or out-of-range values. Use ``UTF8Validation``
/// when well-formedness matters.
public enum UTF8Decode {
    /// Decodes the scalar beginning at `i` within the `0..<count` window, returning its value and
    /// byte width (1–4). A lead byte whose continuation bytes do not fit within `count`, or any
    /// non-lead/invalid byte, decodes to the replacement scalar `(0xFFFD, 1)`. The caller
    /// guarantees `i < count`.
    @inlinable
    public static func scalar<C: RandomAccessCollection>(
        _ bytes: C, at i: Int, count n: Int
    ) -> (value: UInt32, width: Int) where C.Element == UInt8, C.Index == Int {
        let b0 = bytes[i]
        if b0 < 0x80 { return (UInt32(b0), 1) }
        if b0 & 0xE0 == 0xC0, i + 1 < n {
            return ((UInt32(b0 & 0x1F) << 6) | UInt32(bytes[i + 1] & 0x3F), 2)
        }
        if b0 & 0xF0 == 0xE0, i + 2 < n {
            return (
                (UInt32(b0 & 0x0F) << 12) | (UInt32(bytes[i + 1] & 0x3F) << 6)
                    | UInt32(bytes[i + 2] & 0x3F), 3
            )
        }
        if b0 & 0xF8 == 0xF0, i + 3 < n {
            return (
                (UInt32(b0 & 0x07) << 18) | (UInt32(bytes[i + 1] & 0x3F) << 12)
                    | (UInt32(bytes[i + 2] & 0x3F) << 6) | UInt32(bytes[i + 3] & 0x3F), 4
            )
        }
        return (0xFFFD, 1)
    }
}

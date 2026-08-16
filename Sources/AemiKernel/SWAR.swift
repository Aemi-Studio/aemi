// SIMD-Within-A-Register byte predicates over a little-endian-loaded `UInt64` word. Each returns a
// word with `0x80` set in exactly the byte lanes matching the predicate (0 elsewhere), so they compose
// with `|`; `mask.trailingZeroBitCount >> 3` then locates the first matching byte. These are the classic
// "Bit Twiddling Hacks" haszero/hasless tricks, factored into the foundation so byte scanners across the
// AD* family — JSON string stop-masks, HTML-escape stop-masks, tokenizers — share one kernel rather than
// re-deriving it. SWAR (not SIMD intrinsics) is deliberate: portable, no per-arch code.
public enum SWAR {
    @usableFromInline static let ones: UInt64 = 0x0101_0101_0101_0101
    @usableFromInline static let high: UInt64 = 0x8080_8080_8080_8080

    /// `0x80` in each byte that is `< n`. Valid for `n <= 0x80`; bytes `>= 0x80` never match (the `& ~v`
    /// term clears any lane whose high bit is already set), so non-ASCII is never flagged.
    @inlinable @inline(__always)
    public static func lessThan(_ v: UInt64, _ n: UInt8) -> UInt64 {
        (v &- (ones &* UInt64(n))) & ~v & high
    }

    /// `0x80` in each byte equal to `c`.
    @inlinable @inline(__always)
    public static func equals(_ v: UInt64, _ c: UInt8) -> UInt64 {
        let x = v ^ (ones &* UInt64(c))
        return (x &- ones) & ~x & high
    }

    /// `0x80` in each non-ASCII byte (`>= 0x80`).
    @inlinable @inline(__always)
    public static func nonASCII(_ v: UInt64) -> UInt64 { v & high }
}

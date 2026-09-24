// SIMD-Within-A-Register byte predicates over a little-endian-loaded `UInt64` word. Each returns a
// word that is zero iff no byte matches the predicate, and otherwise has `0x80` set in the FIRST
// (lowest) matching byte lane and in no lane below it, so they compose with `|` and
// `mask.trailingZeroBitCount >> 3` locates the first matching byte. Only that first lane is exact:
// `lessThan` and `equals` subtract across the whole word, and the borrow out of a matching lane can
// flag the lane above it: `equals(0xFFFF_FFFF_FFFF_0100, 0x00)` flags lanes 0 and 1, though only
// lane 0 is zero. Never popcount a mask or walk its lanes. These are the classic "Bit Twiddling
// Hacks" haszero/hasless tricks, factored into the foundation so byte scanners across the AD*
// family — JSON string stop-masks, HTML-escape stop-masks, tokenizers — share one kernel rather than
// re-deriving it. SWAR (not SIMD intrinsics) is deliberate: portable, no per-arch code.
public enum SWAR {
    @usableFromInline static let ones: UInt64 = 0x0101_0101_0101_0101
    @usableFromInline static let high: UInt64 = 0x8080_8080_8080_8080

    /// `0x80` in the first byte that is `< n`; lanes above it may be flagged falsely (see the type
    /// note). Valid for `n <= 0x80`; bytes `>= 0x80` never match (the `& ~v` term clears any lane whose
    /// high bit is already set), so non-ASCII is never flagged.
    @inlinable @inline(__always)
    public static func lessThan(_ v: UInt64, _ n: UInt8) -> UInt64 {
        (v &- (ones &* UInt64(n))) & ~v & high
    }

    /// `0x80` in the first byte equal to `c`; lanes above it may be flagged falsely (see the type note).
    @inlinable @inline(__always)
    public static func equals(_ v: UInt64, _ c: UInt8) -> UInt64 {
        let x = v ^ (ones &* UInt64(c))
        return (x &- ones) & ~x & high
    }

    /// `0x80` in each non-ASCII byte (`>= 0x80`) — exact in every lane, as no arithmetic crosses lanes.
    @inlinable @inline(__always)
    public static func nonASCII(_ v: UInt64) -> UInt64 { v & high }
}

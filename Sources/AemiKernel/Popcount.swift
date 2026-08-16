internal import AemiKernels

/// Population count (set-bit count) and packed-bit Hamming distance — family-wide bit primitives.
///
/// The semantic-search tier sign-quantizes embeddings to packed bit vectors and ranks them by
/// Hamming distance (XOR + popcount), so these live in the zero-dependency `AemiKernel` kernel rather
/// than in any one leaf consumer. Two paths, proven bit-identical:
///   - the **SWAR** path folds 8 bytes per step into a `UInt64` and counts the differing bits with a
///     parallel-bit-count (`Hacker's Delight` §5-1), then handles the `< 8`-byte remainder;
///   - the **byte-LUT** path sums an 8-bit popcount table per differing byte — the readable
///     reference. Because XOR is bitwise and popcount is additive over bits, summing per-byte and
///     per-word popcounts of the same buffers yields the identical total; `Popcount.equivalent`
///     asserts that over a buffer and the test suite fuzzes it.
///
/// Mirrors the JS reference `hamming` (byte-LUT) / `hammingU32` (SWAR) in
/// apple-docs `src/search/embedding.js`: `d = Σ POPCOUNT[a[i] ^ b[i]]`. SE-0458 strict memory
/// safety: every pointer load is `unsafe`-annotated.
public enum Popcount {
    /// Set bits in a 64-bit word via SWAR (no `UInt64.nonzeroBitCount` dependency, so the lowering is
    /// explicit and identical on every target). Matches the JS 32-bit SWAR folded to 64 bits.
    @inlinable
    public static func count(_ word: UInt64) -> Int {
        var v = word
        v = v &- ((v >> 1) & 0x5555_5555_5555_5555)
        v = (v & 0x3333_3333_3333_3333) &+ ((v >> 2) & 0x3333_3333_3333_3333)
        v = (v &+ (v >> 4)) & 0x0F0F_0F0F_0F0F_0F0F
        return Int((v &* 0x0101_0101_0101_0101) >> 56)
    }

    /// Set bits in a 32-bit word via SWAR — the exact `hammingU32` inner step from the JS reference,
    /// exposed for callers that scan 32-bit-word-aligned codes.
    @inlinable
    public static func count(_ word: UInt32) -> Int {
        var v = word
        v = v &- ((v >> 1) & 0x5555_5555)
        v = (v & 0x3333_3333) &+ ((v >> 2) & 0x3333_3333)
        v = (v &+ (v >> 4)) & 0x0F0F_0F0F
        return Int((v &* 0x0101_0101) >> 24)
    }

    /// 8-bit popcount lookup table (`POPCOUNT[i] = (i & 1) + POPCOUNT[i >> 1]`), the byte-LUT
    /// reference the JS `hamming` path uses.
    @usableFromInline
    static let table256: [UInt8] = {
        var t = [UInt8](repeating: 0, count: 256)
        for i in 1 ..< 256 { t[i] = (UInt8(i & 1)) &+ t[i >> 1] }
        return t
    }()

    /// Hamming distance (`Σ popcount(a[i] ^ b[i])`) between two `count`-byte packed bit vectors, via the
    /// runtime-dispatched SIMD kernel (NEON `cnt` on arm64, hardware `POPCNT` on x86-64, SWAR fallback).
    /// The distance is an exact integer, so it is bit-identical to the byte-LUT reference regardless of
    /// backend. Never reads past `count`. Endianness-agnostic — popcount is order-free over the XOR.
    @inlinable
    public static func hammingDistance(
        _ a: UnsafeRawBufferPointer, _ b: UnsafeRawBufferPointer, count: Int
    ) -> Int {
        // Owner/bounds: caller owns `a[0 ..< count]` and `b[0 ..< count]`; both are read-only, never
        // escape, and the kernel never reads past `count`.
        assert(count >= 0, "Popcount.hammingDistance requires a non-negative count")
        return unsafe hammingDistanceKernel(a, b, count)
    }

    /// Bridges the raw buffers to `AemiKernels.hammingDistance` (kept out of the `@inlinable` surface so
    /// only an internal import of `AemiKernels` is needed).
    @usableFromInline
    static func hammingDistanceKernel(
        _ a: UnsafeRawBufferPointer, _ b: UnsafeRawBufferPointer, _ count: Int
    ) -> Int {
        guard count > 0, let baseA = a.baseAddress, let baseB = b.baseAddress else { return 0 }
        let pointerA = unsafe baseA.assumingMemoryBound(to: UInt8.self)
        let pointerB = unsafe baseB.assumingMemoryBound(to: UInt8.self)
        return unsafe AemiKernels.hammingDistance(pointerA, pointerB, count: count)
    }

    /// Hamming distance via the byte-LUT reference path — one table lookup per differing byte, the
    /// readable mirror of the JS `hamming`. `Popcount.equivalent` proves it equals the SWAR path.
    @inlinable
    public static func hammingDistanceLUT(
        _ a: UnsafeRawBufferPointer, _ b: UnsafeRawBufferPointer, count: Int
    ) -> Int {
        assert(count >= 0, "Popcount.hammingDistanceLUT requires a non-negative count")
        var distance = 0
        for i in 0 ..< count {
            let xa = unsafe a.loadUnaligned(fromByteOffset: i, as: UInt8.self)
            let xb = unsafe b.loadUnaligned(fromByteOffset: i, as: UInt8.self)
            distance &+= Int(table256[Int(xa ^ xb)])
        }
        return distance
    }

    /// `[UInt8]` convenience over the SWAR path. Compares `min(a.count, b.count)` bytes when widths
    /// differ; callers that require equal widths check first (the semantic tier filters on width).
    @inlinable
    public static func hammingDistance(_ a: [UInt8], _ b: [UInt8]) -> Int {
        let n = Swift.min(a.count, b.count)
        return a.withUnsafeBytes { pa in
            b.withUnsafeBytes { pb in
                unsafe hammingDistance(pa, pb, count: n)
            }
        }
    }

    /// Asserts the SWAR and byte-LUT paths return the identical distance over `a`/`b` (`count`
    /// bytes), returning that distance. The bit-identical guarantee both paths must uphold —
    /// exercised by the test suite and usable as a debug self-check at a call site.
    @inlinable
    @discardableResult
    public static func equivalent(
        _ a: UnsafeRawBufferPointer, _ b: UnsafeRawBufferPointer, count: Int
    ) -> Int {
        let swar = unsafe hammingDistance(a, b, count: count)
        let lut = unsafe hammingDistanceLUT(a, b, count: count)
        assert(swar == lut, "Popcount SWAR and byte-LUT Hamming distances diverged")
        return swar
    }
}

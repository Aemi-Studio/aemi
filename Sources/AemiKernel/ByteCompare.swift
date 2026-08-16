/// Word-at-a-time byte-buffer equality. Compares 8 bytes per step and then the `< 8`-byte
/// remainder, so it never reads past `count`; equality is endianness-agnostic (both sides load
/// identically), so no byte swapping is needed. Pure standard library (no C `memcmp`), so it stays
/// `@inlinable` and the optimizer lowers it to a bulk compare. Relocated from ADJSON's `JSONKey`
/// (the escape-aware key-matching variants stay in ADJSON, since they are JSON-specific).
public enum ByteCompare {
    @inlinable
    public static func equal(_ a: UnsafePointer<UInt8>, _ b: UnsafePointer<UInt8>, _ count: Int) -> Bool {
        // Owner/bounds: caller owns `a[0 ..< count]` and `b[0 ..< count]` for this call; both pointers
        // are read-only and never escape. The word + remainder loops never read past `count`.
        assert(count >= 0, "ByteCompare.equal requires a non-negative count")
        var i = 0
        while i &+ 8 <= count {
            let wa = unsafe UnsafeRawPointer(a + i).loadUnaligned(as: UInt64.self)
            let wb = unsafe UnsafeRawPointer(b + i).loadUnaligned(as: UInt64.self)
            if wa != wb { return false }
            i &+= 8
        }
        while i < count {
            let x = unsafe a[i]
            let y = unsafe b[i]
            if x != y { return false }
            i &+= 1
        }
        return true
    }
}

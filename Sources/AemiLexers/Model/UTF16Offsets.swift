/// Ascending UTF-8 byte offsets moved to UTF-16 offsets in one forward walk over the bytes, for tokens a scanner found
/// in bytes and a caller places in a `String`'s UTF-16 view or a text store.
public enum UTF16Offsets {
    /// Moves `byte` forward to `end`, adding to `unit` the UTF-16 units of the characters it passes: one for a lead
    /// byte, two for the lead of a four-byte character, none for a continuation byte. Counts eight bytes at a time: a
    /// continuation byte has its top bit set and the next one clear, a four-byte lead its top four set.
    /// - Complexity: O(`end` - `byte`)
    @inlinable
    public static func advance(_ byte: inout Int, to end: Int, in bytes: Span<UInt8>, counting unit: inout Int) {
        let raw = bytes.bytes
        let top: UInt64 = 0x8080_8080_8080_8080
        while byte + 8 <= end {
            let word = raw.unsafeLoadUnaligned(fromByteOffset: byte, as: UInt64.self)
            let continuations = word & ~(word << 1) & top
            let fourByteLeads = word & (word << 1) & (word << 2) & (word << 3) & top
            unit += 8 - continuations.nonzeroBitCount + fourByteLeads.nonzeroBitCount
            byte += 8
        }
        while byte < end {
            let value = bytes[byte]
            unit += (value & 0xC0 == 0x80 ? 0 : 1) + (value >= 0xF0 ? 1 : 0)
            byte += 1
        }
    }

    /// The offset of the first byte of `bytes` at or after `start` that is not ASCII, or `bytes.count` when none is.
    /// Reads eight bytes at a time.
    /// - Complexity: O(the offset returned - `start`)
    static func firstNonASCII(in bytes: Span<UInt8>, from start: Int) -> Int {
        var index = start
        let raw = bytes.bytes
        while index + 8 <= bytes.count {
            let high =
                UInt64(littleEndian: raw.unsafeLoadUnaligned(fromByteOffset: index, as: UInt64.self))
                & 0x8080_8080_8080_8080
            if high != 0 { return index + high.trailingZeroBitCount / 8 }
            index += 8
        }
        while index < bytes.count, bytes[index] < 0x80 { index += 1 }
        return index
    }
}

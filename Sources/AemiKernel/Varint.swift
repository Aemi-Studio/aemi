/// LEB128 variable-length integers and zig-zag signed mapping — the compact integer codec shared
/// by free lists, record codecs, and posting lists. Relocated from ADSQL's `ByteCodec`.
public enum Varint {
    /// The maximum number of bytes an unsigned LEB128 varint can occupy (`ceil(64 / 7) == 10`). A
    /// caller building into a fixed-capacity `OutputSpan` reserves this per varint as a safe bound.
    public static let maxEncodedLength = 10

    /// Appends `value` as an unsigned LEB128 varint (7 bits per byte, high bit = continuation).
    public static func append(_ value: UInt64, to bytes: inout [UInt8]) {
        var v = value
        while v >= 0x80 {
            bytes.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        bytes.append(UInt8(v))
    }

    /// Appends `value` as an unsigned LEB128 varint into an `OutputSpan` — the copy-free building form
    /// of the `[UInt8]` overload, for codecs that assemble a record into a single exclusively-owned
    /// buffer (no reference counting, no copy-on-write). The caller must leave at least
    /// ``maxEncodedLength`` free elements; the span's fixed capacity is its bound.
    public static func append(_ value: UInt64, to out: inout OutputSpan<UInt8>) {
        var v = value
        while v >= 0x80 {
            out.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        out.append(UInt8(v))
    }

    /// Reads a varint from a raw buffer, advancing `offset`. Returns `nil` on truncation or on a
    /// value that would overflow 64 bits — never traps (the no-trap-at-boundaries rule).
    ///
    /// On every outcome `offset` advances past the bytes consumed (it lands at `bytes.count` on
    /// truncation, and just past the offending byte on overflow), so a caller looping over a buffer
    /// always makes progress and cannot spin on a malformed varint.
    public static func read(_ bytes: UnsafeRawBufferPointer, _ offset: inout Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while offset < bytes.count {
            let byte = unsafe bytes[offset]
            offset += 1
            // The 10th group (shift 63) contributes only bit 63: any higher payload bit, or a
            // continuation byte demanding an 11th group, exceeds 64 bits — fail cleanly, never truncate.
            if shift == 63, byte & 0x7F > 0x01 { return nil }
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            if shift > 63 { return nil }
        }
        return nil
    }

    /// `[UInt8]` overload (bounds-checked) for callers decoding from arrays. Delegates to the
    /// raw-buffer reader so the decode and overflow logic has a single home.
    public static func read(_ bytes: [UInt8], _ offset: inout Int) -> UInt64? {
        bytes.withUnsafeBytes { unsafe read($0, &offset) }
    }

    /// Maps a signed integer to an unsigned varint-friendly value (small magnitudes ⇒ short codes).
    @inline(__always)
    public static func zigzag(_ value: Int64) -> UInt64 {
        UInt64(bitPattern: (value << 1) ^ (value >> 63))
    }

    /// Inverse of ``zigzag(_:)``.
    @inline(__always)
    public static func unzigzag(_ value: UInt64) -> Int64 {
        Int64(bitPattern: (value >> 1)) ^ -Int64(bitPattern: value & 1)
    }
}

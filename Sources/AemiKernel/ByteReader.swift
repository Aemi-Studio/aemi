/// Bounds-checked little-endian reader over a raw byte buffer. Every read returns `nil` past the
/// end instead of trapping — the no-trap-at-boundaries rule (a malformed or truncated buffer must
/// surface as a clean failure, never abort the host process). Relocated from apple-docs'
/// `RequestReader`; the length-prefixed / null-sentinel *wire framing* stays in apple-docs, since
/// that is FFI-protocol-specific rather than a domain-neutral primitive.
///
/// `@safe`: the naked buffer pointer is private and every read is bounds-checked, so the type
/// presents a safe interface over its unsafe storage (the caller guarantees the buffer outlives
/// the reader, exactly as for `withUnsafeBytes`).
@safe public struct ByteReader {
    private let buf: UnsafeRawBufferPointer
    public private(set) var offset: Int

    public init(_ buf: UnsafeRawBufferPointer) {
        unsafe self.buf = buf
        self.offset = 0
    }

    public var remaining: Int { unsafe buf.count - offset }

    @inline(__always)
    public mutating func u32() -> UInt32? {
        guard remaining >= 4, let base = unsafe buf.baseAddress else { return nil }
        let value = unsafe base.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
        offset += 4
        return UInt32(littleEndian: value)
    }

    @inline(__always)
    public mutating func u64() -> UInt64? {
        guard remaining >= 8, let base = unsafe buf.baseAddress else { return nil }
        let value = unsafe base.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
        offset += 8
        return UInt64(littleEndian: value)
    }

    @inline(__always)
    public mutating func f64() -> Double? {
        guard remaining >= 8, let base = unsafe buf.baseAddress else { return nil }
        let bits = unsafe base.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
        offset += 8
        return Double(bitPattern: UInt64(littleEndian: bits))
    }

    @inline(__always)
    public mutating func u8() -> UInt8? {
        guard remaining >= 1, let base = unsafe buf.baseAddress else { return nil }
        let value = unsafe base.loadUnaligned(fromByteOffset: offset, as: UInt8.self)
        offset += 1
        return value
    }

    @inline(__always)
    public mutating func u16() -> UInt16? {
        guard remaining >= 2, let base = unsafe buf.baseAddress else { return nil }
        let value = unsafe base.loadUnaligned(fromByteOffset: offset, as: UInt16.self)
        offset += 2
        return UInt16(littleEndian: value)
    }

    @inline(__always)
    public mutating func u16be() -> UInt16? {
        guard remaining >= 2, let base = unsafe buf.baseAddress else { return nil }
        let value = unsafe base.loadUnaligned(fromByteOffset: offset, as: UInt16.self)
        offset += 2
        return UInt16(bigEndian: value)
    }

    @inline(__always)
    public mutating func u32be() -> UInt32? {
        guard remaining >= 4, let base = unsafe buf.baseAddress else { return nil }
        let value = unsafe base.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
        offset += 4
        return UInt32(bigEndian: value)
    }

    @inline(__always)
    public mutating func u64be() -> UInt64? {
        guard remaining >= 8, let base = unsafe buf.baseAddress else { return nil }
        let value = unsafe base.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
        offset += 8
        return UInt64(bigEndian: value)
    }

    /// A no-copy view over the next `count` bytes, or `nil` if out of bounds.
    @inline(__always)
    public mutating func bytes(_ count: Int) -> UnsafeRawBufferPointer? {
        guard count >= 0, remaining >= count, let base = unsafe buf.baseAddress else { return nil }
        let view = unsafe UnsafeRawBufferPointer(start: base + offset, count: count)
        offset += count
        return unsafe view
    }

    /// Advances to the next 8-byte boundary (relative to buffer start). Returns `false` if the
    /// padding would run past the end.
    @inline(__always)
    public mutating func align8() -> Bool {
        let pad = (8 - (offset % 8)) % 8
        guard remaining >= pad else { return false }
        offset += pad
        return true
    }

    /// Advances past `count` bytes, returning `false` (and leaving `offset` unchanged) if fewer
    /// remain or `count` is negative — the same no-trap contract as the typed reads.
    @inline(__always)
    public mutating func skip(_ count: Int) -> Bool {
        guard count >= 0, remaining >= count else { return false }
        offset += count
        return true
    }
}

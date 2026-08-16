/// Unaligned-safe little- and big-endian integer loads/stores over raw byte buffers.
///
/// On-disk and on-wire formats are byte-oriented and frequently unaligned, so these go through
/// `loadUnaligned` / `storeBytes` rather than a typed bind. Relocated from ADSQL's `ByteCodec`,
/// where the storage format is little-endian everywhere except the order-preserving key codec
/// (the one big-endian region, served by ``loadBE64(_:)``).
extension UnsafeRawBufferPointer {
    @inlinable
    public func loadLE16(_ offset: Int) -> UInt16 {
        unsafe UInt16(littleEndian: loadUnaligned(fromByteOffset: offset, as: UInt16.self))
    }
    @inlinable
    public func loadLE32(_ offset: Int) -> UInt32 {
        unsafe UInt32(littleEndian: loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }
    @inlinable
    public func loadLE64(_ offset: Int) -> UInt64 {
        unsafe UInt64(littleEndian: loadUnaligned(fromByteOffset: offset, as: UInt64.self))
    }
    /// Big-endian loads (a single byte-swapped load, not a shift loop) for order-preserving keys.
    @inlinable
    public func loadBE16(_ offset: Int) -> UInt16 {
        unsafe UInt16(bigEndian: loadUnaligned(fromByteOffset: offset, as: UInt16.self))
    }
    @inlinable
    public func loadBE32(_ offset: Int) -> UInt32 {
        unsafe UInt32(bigEndian: loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }
    @inlinable
    public func loadBE64(_ offset: Int) -> UInt64 {
        unsafe UInt64(bigEndian: loadUnaligned(fromByteOffset: offset, as: UInt64.self))
    }
}

extension UnsafeMutableRawBufferPointer {
    // The little-endian *loads* mirror the `UnsafeRawBufferPointer` ones; delegate through an
    // immutable view so the bodies live in one place (all `@inlinable`, so each still lowers to a
    // single unaligned load).
    @inlinable
    public func loadLE16(_ offset: Int) -> UInt16 { unsafe UnsafeRawBufferPointer(self).loadLE16(offset) }
    @inlinable
    public func loadLE32(_ offset: Int) -> UInt32 { unsafe UnsafeRawBufferPointer(self).loadLE32(offset) }
    @inlinable
    public func loadLE64(_ offset: Int) -> UInt64 { unsafe UnsafeRawBufferPointer(self).loadLE64(offset) }
    @inlinable
    public func loadBE16(_ offset: Int) -> UInt16 { unsafe UnsafeRawBufferPointer(self).loadBE16(offset) }
    @inlinable
    public func loadBE32(_ offset: Int) -> UInt32 { unsafe UnsafeRawBufferPointer(self).loadBE32(offset) }
    @inlinable
    public func loadBE64(_ offset: Int) -> UInt64 { unsafe UnsafeRawBufferPointer(self).loadBE64(offset) }
    @inlinable
    public func storeLE16(_ value: UInt16, at offset: Int) {
        unsafe storeBytes(of: value.littleEndian, toByteOffset: offset, as: UInt16.self)
    }
    @inlinable
    public func storeLE32(_ value: UInt32, at offset: Int) {
        unsafe storeBytes(of: value.littleEndian, toByteOffset: offset, as: UInt32.self)
    }
    @inlinable
    public func storeLE64(_ value: UInt64, at offset: Int) {
        unsafe storeBytes(of: value.littleEndian, toByteOffset: offset, as: UInt64.self)
    }
    @inlinable
    public func storeBE16(_ value: UInt16, at offset: Int) {
        unsafe storeBytes(of: value.bigEndian, toByteOffset: offset, as: UInt16.self)
    }
    @inlinable
    public func storeBE32(_ value: UInt32, at offset: Int) {
        unsafe storeBytes(of: value.bigEndian, toByteOffset: offset, as: UInt32.self)
    }
    @inlinable
    public func storeBE64(_ value: UInt64, at offset: Int) {
        unsafe storeBytes(of: value.bigEndian, toByteOffset: offset, as: UInt64.self)
    }
}

// MARK: - Append-form little-endian stores for a growing [UInt8]

// Wire- and disk-format builders assemble bytes by *appending* to a `[UInt8]` (a response frame, a
// packed quantizer record), not by storing into a pre-sized buffer at an offset. These helpers append
// the little-endian byte sequence of `value` in a single bounded copy of the byte-swapped scalar's
// in-memory representation — which is little-endian on every host (the swap happens on a big-endian
// host), so the appended bytes are identical regardless of CPU endianness. One canonical encoder
// replaces the hand-rolled per-shift `append` loops (e.g. eight `append`s per `UInt64`) the consumers
// otherwise re-roll. Concrete `[UInt8]` (not a generic `RangeReplaceableCollection`) so the contiguous
// `append(contentsOf:)` fast path is the only lowering — the same reason the number/byte kernels here
// stay concrete.
extension Array where Element == UInt8 {
    @inlinable
    public mutating func appendLE16(_ value: UInt16) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { unsafe append(contentsOf: $0) }
    }
    @inlinable
    public mutating func appendLE32(_ value: UInt32) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { unsafe append(contentsOf: $0) }
    }
    @inlinable
    public mutating func appendLE64(_ value: UInt64) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { unsafe append(contentsOf: $0) }
    }
}

// MARK: - Span parallels

// The `RawSpan` / `MutableRawSpan` parallels of the buffer-pointer helpers above, for callers
// vending a compiler-checked, lifetime-bounded byte view instead of a bare pointer (e.g. ADDB's
// `PageBuf.withMutableBytes` page scope). Same little-/big-endian wrapping, same single unaligned
// load/store lowering; the reads stay `unsafe` (the strict-memory-safety mode flags
// `unsafeLoadUnaligned`), the bounds-checked `storeBytes` does not.
extension RawSpan {
    @inlinable
    public func loadLE16(_ offset: Int) -> UInt16 {
        unsafe UInt16(littleEndian: unsafeLoadUnaligned(fromByteOffset: offset, as: UInt16.self))
    }
    @inlinable
    public func loadLE32(_ offset: Int) -> UInt32 {
        unsafe UInt32(littleEndian: unsafeLoadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }
    @inlinable
    public func loadLE64(_ offset: Int) -> UInt64 {
        unsafe UInt64(littleEndian: unsafeLoadUnaligned(fromByteOffset: offset, as: UInt64.self))
    }
    @inlinable
    public func loadBE16(_ offset: Int) -> UInt16 {
        unsafe UInt16(bigEndian: unsafeLoadUnaligned(fromByteOffset: offset, as: UInt16.self))
    }
    @inlinable
    public func loadBE32(_ offset: Int) -> UInt32 {
        unsafe UInt32(bigEndian: unsafeLoadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }
    @inlinable
    public func loadBE64(_ offset: Int) -> UInt64 {
        unsafe UInt64(bigEndian: unsafeLoadUnaligned(fromByteOffset: offset, as: UInt64.self))
    }
}

extension MutableRawSpan {
    // The little-/big-endian *loads* read through the borrowing `.bytes` (`RawSpan`) view so the
    // bodies live in one place; all `@inlinable`, so each still lowers to a single unaligned load.
    // (The `unsafe` already lives inside each `RawSpan.loadXX`, so `.bytes` + the delegate is safe.)
    @inlinable
    public func loadLE16(_ offset: Int) -> UInt16 { bytes.loadLE16(offset) }
    @inlinable
    public func loadLE32(_ offset: Int) -> UInt32 { bytes.loadLE32(offset) }
    @inlinable
    public func loadLE64(_ offset: Int) -> UInt64 { bytes.loadLE64(offset) }
    @inlinable
    public func loadBE16(_ offset: Int) -> UInt16 { bytes.loadBE16(offset) }
    @inlinable
    public func loadBE32(_ offset: Int) -> UInt32 { bytes.loadBE32(offset) }
    @inlinable
    public func loadBE64(_ offset: Int) -> UInt64 { bytes.loadBE64(offset) }
    @inlinable
    public mutating func storeLE16(_ value: UInt16, at offset: Int) {
        storeBytes(of: value.littleEndian, toByteOffset: offset, as: UInt16.self)
    }
    @inlinable
    public mutating func storeLE32(_ value: UInt32, at offset: Int) {
        storeBytes(of: value.littleEndian, toByteOffset: offset, as: UInt32.self)
    }
    @inlinable
    public mutating func storeLE64(_ value: UInt64, at offset: Int) {
        storeBytes(of: value.littleEndian, toByteOffset: offset, as: UInt64.self)
    }
    @inlinable
    public mutating func storeBE16(_ value: UInt16, at offset: Int) {
        storeBytes(of: value.bigEndian, toByteOffset: offset, as: UInt16.self)
    }
    @inlinable
    public mutating func storeBE32(_ value: UInt32, at offset: Int) {
        storeBytes(of: value.bigEndian, toByteOffset: offset, as: UInt32.self)
    }
    @inlinable
    public mutating func storeBE64(_ value: UInt64, at offset: Int) {
        storeBytes(of: value.bigEndian, toByteOffset: offset, as: UInt64.self)
    }
}

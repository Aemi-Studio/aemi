//
//  AemiKernels+Checksums.swift
//  AemiKernels
//
//  CRC-32C, the bit count of a buffer, and the ASCII prefix of UTF-16LE text (ADR 0020).
//

internal import CAemiKernels

extension AemiKernels {
    /// CRC-32C of `base[0..<count]` continued from `crc`: raw, no inversion (the caller chooses seed and final xor).
    /// `.scalar` forces the table reference.
    ///
    /// Owner/bounds: the caller owns `base[0..<count]` for the call.
    public static func crc32c(_ crc: UInt32, _ base: UnsafePointer<UInt8>, count: Int, backend: Backend = .fastest)
        -> UInt32
    {
        guard count > 0 else { return crc }
        if case .scalar = backend { return unsafe adf_crc32c_update_scalar(crc, base, count) }
        return unsafe adf_crc32c_update(crc, base, count)
    }

    /// The number of set bits in `base[0..<count]`. `.scalar` forces the reference.
    public static func bitCount(_ base: UnsafePointer<UInt8>, count: Int, backend: Backend = .fastest) -> Int {
        guard count > 0 else { return 0 }
        if case .scalar = backend { return Int(unsafe adf_bit_count_scalar(base, count)) }
        return Int(unsafe adf_bit_count(base, count))
    }

    /// How many of the `units` UTF-16LE code units at `utf16LE` are below 0x80 before the first that is not, each copied
    /// as one byte to `ascii` (room for `units` bytes). `.scalar` forces the reference.
    public static func asciiPrefix(
        utf16LE base: UnsafePointer<UInt8>, units: Int, into ascii: UnsafeMutablePointer<UInt8>,
        backend: Backend = .fastest
    ) -> Int {
        guard units > 0 else { return 0 }
        if case .scalar = backend { return Int(unsafe adf_utf16le_ascii_prefix_scalar(base, units, ascii)) }
        return Int(unsafe adf_utf16le_ascii_prefix(base, units, ascii))
    }
}

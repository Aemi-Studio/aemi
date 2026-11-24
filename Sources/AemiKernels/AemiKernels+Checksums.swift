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

    /// IEEE 802.3 / ISO-HDLC / gzip CRC-32 (RFC 1952 §8; reflected polynomial `0xEDB88320`) of
    /// `base[0..<count]` continued from `crc`: raw, no inversion (caller supplies `0xFFFFFFFF` seed
    /// and performs final `^ 0xFFFFFFFF`). `.scalar` forces the slicing-by-8 reference.
    ///
    /// Owner/bounds: the caller owns `base[0..<count]` for the call.
    public static func crc32IEEE(
        _ crc: UInt32,
        _ base: UnsafePointer<UInt8>,
        count: Int,
        backend: Backend = .fastest
    ) -> UInt32 {
        guard count > 0 else { return crc }
        if case .scalar = backend { return unsafe adf_crc32_ieee_update_scalar(crc, base, count) }
        return unsafe adf_crc32_ieee_update(crc, base, count)
    }

    /// Applies a repeating 4-byte XOR mask in place (`base[i] ^= mask[i & 3]`) using NEON/SSE2
    /// (64 bytes per iteration). `mask` is passed as a big-endian packed `UInt32` whose bytes
    /// `(mask >> 24, mask >> 16, mask >> 8, mask)` are XORed at offsets `0, 1, 2, 3` respectively
    /// (matching RFC 6455 §5.3 network-order masking keys). `.scalar` forces the byte-by-byte reference.
    ///
    /// Owner/bounds: the caller owns `base[0..<count]` mutably for the call.
    public static func xorMask4(
        _ base: UnsafeMutablePointer<UInt8>,
        count: Int,
        mask: UInt32,
        backend: Backend = .fastest
    ) {
        guard count > 0 else { return }
        var key = mask.bigEndian
        withUnsafeBytes(of: &key) { raw in
            guard let ptr = unsafe raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            if case .scalar = backend {
                unsafe adf_xor_mask4_scalar(base, count, ptr)
            } else {
                unsafe adf_xor_mask4(base, count, ptr)
            }
        }
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
        utf16LE base: UnsafePointer<UInt8>,
        units: Int,
        into ascii: UnsafeMutablePointer<UInt8>,
        backend: Backend = .fastest
    ) -> Int {
        guard units > 0 else { return 0 }
        if case .scalar = backend { return Int(unsafe adf_utf16le_ascii_prefix_scalar(base, units, ascii)) }
        return Int(unsafe adf_utf16le_ascii_prefix(base, units, ascii))
    }
}

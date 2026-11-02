#if !compiler(>=6.4)
    #if canImport(Darwin)
        internal import Darwin
    #elseif canImport(Glibc)
        internal import Glibc
    #endif
#endif

/// Whether two byte buffers hold the same bytes: the interner's key comparison.
///
/// With Swift 6.4 it reads both through `RawSpan`'s bounds-checked loads (SE-0525) instead of calling libc: 16 bytes a
/// step, then the last 8 or 4 bytes, overlapping what was already compared, so a key of 4 bytes or more never takes a
/// byte loop. A load past either end traps rather than reads. Measured against `memcmp` on equal keys: as fast to 32 bytes,
/// two to four times slower from 256 (keys are identifiers and USRs, mostly short). Not constant-time: these are keys,
/// not secrets (`AemiArgon2`'s comparison is for those). Swift 6.3 has no safe load and keeps `memcmp`.
@inline(__always)
func bytesEqual(_ a: UnsafeRawBufferPointer, _ b: UnsafeRawBufferPointer) -> Bool {
    guard a.count == b.count else { return false }
    #if compiler(>=6.4)
        return bytesEqual(unsafe a.bytes, unsafe b.bytes)
    #else
        guard a.count > 0, let left = a.baseAddress, let right = b.baseAddress else { return true }
        return unsafe memcmp(left, right, a.count) == 0
    #endif
}

#if compiler(>=6.4)
    /// Whether two spans of the same length hold the same bytes; every load is bounds-checked.
    func bytesEqual(_ a: RawSpan, _ b: RawSpan) -> Bool {
        let count = a.byteCount
        guard count == b.byteCount else { return false }
        if count >= 8 {
            var offset = 0
            while offset + 16 <= count {
                if a.load(fromByteOffset: offset, as: SIMD16<UInt8>.self)
                    != b.load(fromByteOffset: offset, as: SIMD16<UInt8>.self)
                {
                    return false
                }
                offset += 16
            }
            if offset + 8 <= count,
                a.load(fromByteOffset: offset, as: UInt64.self) != b.load(fromByteOffset: offset, as: UInt64.self)
            {
                return false
            }
            return a.load(fromByteOffset: count - 8, as: UInt64.self)
                == b.load(fromByteOffset: count - 8, as: UInt64.self)
        }
        if count >= 4 {
            return a.load(fromByteOffset: 0, as: UInt32.self) == b.load(fromByteOffset: 0, as: UInt32.self)
                && a.load(fromByteOffset: count - 4, as: UInt32.self)
                    == b.load(fromByteOffset: count - 4, as: UInt32.self)
        }
        var difference: UInt8 = 0
        for offset in 0 ..< count {
            difference |=
                a.load(fromByteOffset: offset, as: UInt8.self) ^ b.load(fromByteOffset: offset, as: UInt8.self)
        }
        return difference == 0
    }
#endif

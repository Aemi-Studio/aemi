/// Pure-Swift xxHash64 (one-shot) — a fast non-cryptographic hash for checksums and bucketing.
///
/// Relocated from ADSQL, where it backs page checksums seeded with the page number (so a page
/// persisted at the wrong offset fails verification). At 16 KiB inputs it comfortably exceeds NVMe
/// read rates, so checksums are never the bottleneck. Not for security-sensitive use — for
/// DoS-resistant hashing of untrusted keys, use the standard library's `Hasher` (SipHash).
public enum XXH64 {
    @usableFromInline static let p1: UInt64 = 0x9E37_79B1_85EB_CA87
    @usableFromInline static let p2: UInt64 = 0xC2B2_AE3D_27D4_EB4F
    @usableFromInline static let p3: UInt64 = 0x1656_67B1_9E37_79F9
    @usableFromInline static let p4: UInt64 = 0x85EB_CA77_C2B2_AE63
    @usableFromInline static let p5: UInt64 = 0x27D4_EB2F_1656_67C5

    @inline(__always)
    @usableFromInline static func rotl(_ x: UInt64, _ r: UInt64) -> UInt64 {
        (x << r) | (x >> (64 - r))
    }

    @inline(__always)
    @usableFromInline static func round(_ acc: UInt64, _ input: UInt64) -> UInt64 {
        rotl(acc &+ input &* p2, 31) &* p1
    }

    @inline(__always)
    @usableFromInline static func mergeRound(_ acc: UInt64, _ val: UInt64) -> UInt64 {
        (acc ^ round(0, val)) &* p1 &+ p4
    }

    @inlinable
    public static func hash(_ bytes: UnsafeRawBufferPointer, seed: UInt64 = 0) -> UInt64 {
        let len = bytes.count
        var offset = 0
        var h: UInt64

        @inline(__always) func u64(_ at: Int) -> UInt64 {
            unsafe UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: at, as: UInt64.self))
        }
        @inline(__always) func u32(_ at: Int) -> UInt32 {
            unsafe UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: at, as: UInt32.self))
        }

        if len >= 32 {
            var v1 = seed &+ p1 &+ p2
            var v2 = seed &+ p2
            var v3 = seed
            var v4 = seed &- p1
            repeat {
                v1 = round(v1, u64(offset))
                v2 = round(v2, u64(offset + 8))
                v3 = round(v3, u64(offset + 16))
                v4 = round(v4, u64(offset + 24))
                offset += 32
            } while offset <= len - 32
            h = rotl(v1, 1) &+ rotl(v2, 7) &+ rotl(v3, 12) &+ rotl(v4, 18)
            h = mergeRound(h, v1)
            h = mergeRound(h, v2)
            h = mergeRound(h, v3)
            h = mergeRound(h, v4)
        } else {
            h = seed &+ p5
        }

        h &+= UInt64(len)

        while offset + 8 <= len {
            h ^= round(0, u64(offset))
            h = rotl(h, 27) &* p1 &+ p4
            offset += 8
        }
        if offset + 4 <= len {
            h ^= UInt64(u32(offset)) &* p1
            h = rotl(h, 23) &* p2 &+ p3
            offset += 4
        }
        while offset < len {
            unsafe h ^= UInt64(bytes[offset]) &* p5
            h = rotl(h, 11) &* p1
            offset += 1
        }

        h ^= h >> 33
        h &*= p2
        h ^= h >> 29
        h &*= p3
        h ^= h >> 32
        return h
    }

    @inlinable
    public static func hash(_ bytes: [UInt8], seed: UInt64 = 0) -> UInt64 {
        bytes.withUnsafeBytes { unsafe hash($0, seed: seed) }
    }
}

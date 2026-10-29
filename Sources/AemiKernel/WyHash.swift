/// wyhash, final version 4.2, with its default secret: a fast non-cryptographic hash for short keys, the one Go, Zig and
/// rapidhash build on (ADR 0019). Equal to the reference `wyhash.h` for every length and seed. Not a defence against keys
/// chosen to collide; for untrusted keys use the standard library's `Hasher` (SipHash).
public enum WyHash {
    // Computed, not stored: an inlined caller in another module then sees constants, not a lazy global per access.
    @inlinable static var s0: UInt64 { 0x2d35_8dcc_aa6c_78a5 }
    @inlinable static var s1: UInt64 { 0x8bb8_4b93_962e_acc9 }
    @inlinable static var s2: UInt64 { 0x4b33_a62e_d433_d4a3 }
    @inlinable static var s3: UInt64 { 0x4d5a_2da5_1de1_aa47 }

    /// The 128-bit product of `a` and `b`, folded: its low half XOR its high half.
    @inlinable @inline(__always)
    static func mix(_ a: UInt64, _ b: UInt64) -> UInt64 {
        let product = a.multipliedFullWidth(by: b)
        return product.low ^ product.high
    }

    /// The hash of `bytes` under `seed`.
    @inlinable
    public static func hash(_ bytes: UnsafeRawBufferPointer, seed: UInt64 = 0) -> UInt64 {
        let n = bytes.count
        var seed = seed ^ mix(seed ^ s0, s1)
        guard n > 0, let p = bytes.baseAddress else {
            let product = s1.multipliedFullWidth(by: seed)
            return mix(product.low ^ s0, product.high ^ s1)
        }
        // Loads from the base pointer: the buffer's own accessors cost a nanosecond and a half more per key, measured.
        @inline(__always) func r8(_ at: Int) -> UInt64 {
            unsafe UInt64(littleEndian: p.loadUnaligned(fromByteOffset: at, as: UInt64.self))
        }
        @inline(__always) func r4(_ at: Int) -> UInt64 {
            unsafe UInt64(UInt32(littleEndian: p.loadUnaligned(fromByteOffset: at, as: UInt32.self)))
        }
        var a: UInt64
        var b: UInt64 = 0
        if n <= 16 {
            if n >= 4 {
                let shift = (n >> 3) << 2
                a = (r4(0) << 32) | r4(shift)
                b = (r4(n - 4) << 32) | r4(n - 4 - shift)
            } else {
                let first = UInt64(unsafe p.load(fromByteOffset: 0, as: UInt8.self))
                let middle = UInt64(unsafe p.load(fromByteOffset: n >> 1, as: UInt8.self))
                let last = UInt64(unsafe p.load(fromByteOffset: n - 1, as: UInt8.self))
                a = (first << 16) | (middle << 8) | last
            }
        } else {
            var offset = 0
            var remaining = n
            if remaining >= 48 {
                var see1 = seed
                var see2 = seed
                repeat {
                    seed = mix(r8(offset) ^ s1, r8(offset + 8) ^ seed)
                    see1 = mix(r8(offset + 16) ^ s2, r8(offset + 24) ^ see1)
                    see2 = mix(r8(offset + 32) ^ s3, r8(offset + 40) ^ see2)
                    offset += 48
                    remaining -= 48
                } while remaining >= 48
                seed ^= see1 ^ see2
            }
            while remaining > 16 {
                seed = mix(r8(offset) ^ s1, r8(offset + 8) ^ seed)
                offset += 16
                remaining -= 16
            }
            a = r8(offset + remaining - 16)
            b = r8(offset + remaining - 8)
        }
        let product = (a ^ s1).multipliedFullWidth(by: b ^ seed)
        return mix(product.low ^ s0 ^ UInt64(n), product.high ^ s1)
    }

    /// The hash of `bytes` under `seed`.
    @inlinable
    public static func hash(_ bytes: [UInt8], seed: UInt64 = 0) -> UInt64 {
        @unsafe func hashBuffer(_ buffer: UnsafeRawBufferPointer) -> UInt64 {
            unsafe hash(buffer, seed: seed)
        }
        return unsafe bytes.withUnsafeBytes(hashBuffer)
    }
}

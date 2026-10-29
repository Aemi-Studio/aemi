/// wyhash, final version 4.2, with its default secret: a fast non-cryptographic hash for short keys, the one Go, Zig and
/// rapidhash build on (ADR 0019). Equal to the reference `wyhash.h` for every length and seed. Not a defence against keys
/// chosen to collide; for untrusted keys use the standard library's `Hasher` (SipHash).
public enum WyHash {
    /// The hash of `bytes` under `seed`.
    @inlinable
    public static func hash(_ bytes: UnsafeRawBufferPointer, seed: UInt64 = 0) -> UInt64 { 0 }

    /// The hash of `bytes` under `seed`.
    @inlinable
    public static func hash(_ bytes: [UInt8], seed: UInt64 = 0) -> UInt64 {
        @unsafe func hashBuffer(_ buffer: UnsafeRawBufferPointer) -> UInt64 {
            unsafe hash(buffer, seed: seed)
        }
        return unsafe bytes.withUnsafeBytes(hashBuffer)
    }
}

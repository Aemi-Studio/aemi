/// SplitMix64 (Steele, Lea and Flood, 2014): a small, seeded, deterministic generator with the published constants, for shipped
/// code that needs a reproducible stream (a simulation, a fuzzer's mutations, a MinHash's seeds). Not for secrets.
/// `AemiTestKit.SeededRNG` is this stream with the test kit's helpers, so a sequence pinned by a seed is the same in both.
public struct SplitMix64: RandomNumberGenerator, Sendable, Hashable {
    @usableFromInline var state: UInt64

    @inlinable
    public init(seed: UInt64) { state = seed }

    @inlinable
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        return Self.mix(state)
    }

    /// SplitMix64's finalizer: a bijection of 64 bits whose every output bit depends on every input bit, usable alone as a mixer.
    @inlinable
    public static func mix(_ value: UInt64) -> UInt64 {
        var z = value
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

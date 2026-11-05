/// SipHash-1-3 with a 128-bit key: the keyed hash for keys an attacker may choose (configuration keys, JSON object keys, HTTP
/// header names), where an unkeyed hash such as ``WyHash`` lets a file be written so every key collides and a hash table turns
/// quadratic. The standard library's `Hasher` is the same function, but `combine(bytes:)` and `finalize()` cost about 70 ns
/// for a short key in a parser's loop (AemiHMMML's profile, issue #5); this one is inlined and reads eight bytes a step.
///
/// The key is secret: ``process`` is drawn at random once per process, like `Hasher`'s seed, so a file cannot be prepared
/// against it; `SWIFT_DETERMINISTIC_HASHING` makes it zero, as it does for `Hasher`, for reproducible runs. A key passed in is
/// for tests and for tables whose layout must be reproducible.
///
/// SipHash-1-3 is the variant Rust's `HashMap`, Python and Swift use for hash tables; SipHash-2-4 (``hash24(_:)``) is the
/// one of the paper and of OpenSSL, kept to check the shared rounds against published values (`KeyedHashTests`).
public struct KeyedHash: Sendable, Hashable {
    public let k0: UInt64
    public let k1: UInt64

    @inlinable
    public init(k0: UInt64, k1: UInt64) {
        self.k0 = k0
        self.k1 = k1
    }

    /// This process's key: random, or zero when the environment sets `SWIFT_DETERMINISTIC_HASHING`.
    public static let process: KeyedHash = {
        #if !hasFeature(Embedded)
            if Environment.isSet("SWIFT_DETERMINISTIC_HASHING") { return KeyedHash(k0: 0, k1: 0) }
        #endif
        var generator = SystemRandomNumberGenerator()
        return KeyedHash(k0: generator.next(), k1: generator.next())
    }()

    /// SipHash-1-3 of `bytes`.
    @inlinable
    public func hash(_ bytes: UnsafeRawBufferPointer) -> UInt64 {
        var state = State(k0: k0, k1: k1)
        unsafe state.absorb(bytes, rounds: 1)
        return state.finish(length: bytes.count, compression: 1, finalization: 3)
    }

    /// SipHash-1-3 of `bytes`.
    @inlinable
    public func hash(_ bytes: [UInt8]) -> UInt64 { bytes.withUnsafeBytes { unsafe hash($0) } }

    /// SipHash-1-3 of `bytes`.
    @inlinable
    public func hash(_ bytes: ArraySlice<UInt8>) -> UInt64 { bytes.withUnsafeBytes { unsafe hash($0) } }

    /// SipHash-1-3 of `tweak`'s eight little-endian bytes followed by `bytes`: one hash for a key within a scope (a table, an
    /// object) without concatenating them.
    @inlinable
    public func hash(tweak: UInt64, _ bytes: UnsafeRawBufferPointer) -> UInt64 {
        var state = State(k0: k0, k1: k1)
        state.compress(tweak, rounds: 1)
        unsafe state.absorb(bytes, rounds: 1)
        return state.finish(length: bytes.count &+ 8, compression: 1, finalization: 3)
    }

    /// As ``hash(tweak:_:)-(_,UnsafeRawBufferPointer)``.
    @inlinable
    public func hash(tweak: UInt64, _ bytes: ArraySlice<UInt8>) -> UInt64 {
        bytes.withUnsafeBytes { unsafe hash(tweak: tweak, $0) }
    }

    /// SipHash-2-4 of `bytes`: the paper's function, which OpenSSL's `SIPHASH` MAC computes.
    @inlinable
    public func hash24(_ bytes: UnsafeRawBufferPointer) -> UInt64 {
        var state = State(k0: k0, k1: k1)
        unsafe state.absorb(bytes, rounds: 2)
        return state.finish(length: bytes.count, compression: 2, finalization: 4)
    }

    /// The four lanes of SipHash, and its rounds.
    @usableFromInline
    struct State {
        @usableFromInline var v0: UInt64
        @usableFromInline var v1: UInt64
        @usableFromInline var v2: UInt64
        @usableFromInline var v3: UInt64

        @inlinable @inline(__always)
        init(k0: UInt64, k1: UInt64) {
            v0 = k0 ^ 0x736F_6D65_7073_6575
            v1 = k1 ^ 0x646F_7261_6E64_6F6D
            v2 = k0 ^ 0x6C79_6765_6E65_7261
            v3 = k1 ^ 0x7465_6462_7974_6573
        }

        @inlinable @inline(__always)
        static func rotl(_ value: UInt64, _ count: UInt64) -> UInt64 { value << count | value >> (64 &- count) }

        @inlinable @inline(__always)
        mutating func round() {
            v0 = v0 &+ v1
            v1 = Self.rotl(v1, 13) ^ v0
            v0 = Self.rotl(v0, 32)
            v2 = v2 &+ v3
            v3 = Self.rotl(v3, 16) ^ v2
            v0 = v0 &+ v3
            v3 = Self.rotl(v3, 21) ^ v0
            v2 = v2 &+ v1
            v1 = Self.rotl(v1, 17) ^ v2
            v2 = Self.rotl(v2, 32)
        }

        @inlinable @inline(__always)
        mutating func compress(_ word: UInt64, rounds: Int) {
            v3 ^= word
            for _ in 0 ..< rounds { round() }
            v0 ^= word
        }

        /// Every whole word of `bytes`, then the tail, which ``finish(length:compression:finalization:)`` closes with the length.
        @inlinable @inline(__always)
        mutating func absorb(_ bytes: UnsafeRawBufferPointer, rounds: Int) {
            let count = bytes.count
            var offset = 0
            while offset + 8 <= count {
                // SAFETY: `offset + 8 <= count`, so the eight bytes are inside `bytes`.
                compress(
                    UInt64(littleEndian: unsafe bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self)),
                    rounds: rounds
                )
                offset += 8
            }
            var tail: UInt64 = 0
            var shift: UInt64 = 0
            while offset < count {
                tail |= UInt64(unsafe bytes[offset]) << shift
                shift += 8
                offset += 1
            }
            pending = tail
        }

        /// The last partial word, waiting for the length byte.
        @usableFromInline var pending: UInt64 = 0

        @inlinable @inline(__always)
        mutating func finish(length: Int, compression: Int, finalization: Int) -> UInt64 {
            compress(pending | UInt64(truncatingIfNeeded: length) << 56, rounds: compression)
            v2 ^= 0xFF
            for _ in 0 ..< finalization { round() }
            return v0 ^ v1 ^ v2 ^ v3
        }
    }
}

#if !hasFeature(Embedded)
    #if canImport(Darwin)
        internal import Darwin
    #elseif canImport(Glibc)
        internal import Glibc
    #elseif canImport(Musl)
        internal import Musl
    #endif

    /// Whether a variable is set in the process environment, without Foundation.
    enum Environment {
        static func isSet(_ name: String) -> Bool {
            name.withCString { unsafe getenv($0) != nil }
        }
    }
#endif

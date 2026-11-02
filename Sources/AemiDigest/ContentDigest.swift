import AemiKernel

#if canImport(CryptoKit)
    import CryptoKit

    private typealias PlatformSHA256 = CryptoKit.SHA256
#else
    import Crypto

    private typealias PlatformSHA256 = Crypto.SHA256
#endif

/// Cryptographic content digests: SHA-256 (FIPS 180-4), for content identity that must hold against a chosen input
/// (snapshot manifests, evidence checksums), where ``XXH64`` and ``WyHash`` are only fast.
///
/// aemi does not implement SHA-256 (ADR 0029): the digest is CryptoKit's on Apple platforms and apple/swift-crypto's
/// (BoringSSL, with its assembly) elsewhere, both on the CPU's SHA instructions. Its own module, so `AemiKernel` stays
/// free of dependencies and builds as Embedded Swift.
public enum ContentDigest {
    /// The size of a SHA-256 digest in bytes.
    public static let sha256ByteCount = 32

    /// The SHA-256 digest of `bytes`.
    public static func sha256(_ bytes: [UInt8]) -> [UInt8] {
        sha256(bytes[...])
    }

    /// The SHA-256 digest of `bytes`.
    public static func sha256(_ bytes: ArraySlice<UInt8>) -> [UInt8] {
        var hasher = SHA256()
        hasher.update(bytes)
        return hasher.finalize()
    }

    /// The SHA-256 digest of `bytes` in lower-case hexadecimal.
    public static func sha256Hex(_ bytes: [UInt8]) -> String {
        String(decoding: Hex.encode(sha256(bytes)), as: UTF8.self)
    }

    /// An incremental SHA-256: ``update(_:)`` with the input in pieces, then ``finalize()`` once.
    public struct SHA256: Sendable {
        private var hasher = PlatformSHA256()

        public init() {}

        public mutating func update(_ bytes: [UInt8]) {
            update(bytes[...])
        }

        public mutating func update(_ bytes: ArraySlice<UInt8>) {
            bytes.withUnsafeBytes { buffer in
                unsafe hasher.update(bufferPointer: buffer)
            }
        }

        /// The digest of everything given to ``update(_:)``. Call once.
        public mutating func finalize() -> [UInt8] {
            Array(hasher.finalize())
        }
    }
}

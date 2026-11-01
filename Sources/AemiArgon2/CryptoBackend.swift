internal import CAemiArgon2

/// Which implementation of the kernels runs. A backend this CPU lacks runs as the best one it has below it.
public enum CryptoBackend: Int32, Sendable, CaseIterable {
    /// The best this CPU has: NEON with SHA3 on Apple silicon, AVX2 or SSSE3 on x86-64.
    case fastest = 0
    /// Portable C, the reference the others are tested against.
    case scalar = 1
    case neon = 2
    /// NEON with SHA3's `xar`, a rotation after a xor in one instruction.
    case neonSHA3 = 3
    case ssse3 = 4
    case avx2 = 5

    /// The backend that runs when this one is asked for.
    public var resolved: CryptoBackend {
        CryptoBackend(rawValue: adf_crypto_resolve(rawValue)) ?? .scalar
    }

    /// Whether this CPU runs this backend itself, rather than one below it.
    public var isAvailable: Bool { self == .fastest || resolved == self }
}

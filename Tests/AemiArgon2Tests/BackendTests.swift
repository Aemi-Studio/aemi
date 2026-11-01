import AemiTestKit
import CAemiArgon2
import Testing

@testable import AemiArgon2

/// Every backend this CPU runs, against the references: the scalar C for G, the RFC and OpenSSL for whole tags.
@Suite
struct BackendTests {
    static let backends = CryptoBackend.allCases.filter { $0 != .fastest && $0.isAvailable }

    @Test(arguments: backends, [Argon2.Variant.d, .i, .id])
    func `each backend gives RFC 9106's tags`(backend: CryptoBackend, variant: Argon2.Variant) throws {
        let expected: [Argon2.Variant: String] = [
            .d: "512b391b6f1162975371d30919734294f868e3be3984f3c1a13a4db9fabe4acb",
            .i: "c814d9d1dc7f37aa13f0d77f2494bda1c8de6b016dd388d29952a4c4672b6ce8",
            .id: "0d640df58d78766c08c037a34a8b53c9d01ef0452d75b65eb52520e96b01e659"
        ]
        let parameters = try Argon2.Parameters(variant: variant, memoryKiB: 32, passes: 3, lanes: 4, tagLength: 32)
        let tag = try Argon2.hash(
            password: Array(repeating: 1, count: 32),
            salt: Array(repeating: 2, count: 16),
            secret: Array(repeating: 3, count: 8),
            associatedData: Array(repeating: 4, count: 12),
            parameters: parameters,
            backend: backend
        )
        #expect(hex(tag) == expected[variant])
    }

    @Test(arguments: backends)
    func `each backend gives OpenSSL's tags, on one thread and on several`(backend: CryptoBackend) throws {
        for vector in ReferenceVectors.argon2 {
            let parameters = try Argon2.Parameters(
                variant: vector.variant,
                memoryKiB: vector.memoryKiB,
                passes: vector.passes,
                lanes: vector.lanes,
                tagLength: vector.tag.count / 2
            )
            for threads in [1, 3, 8] {
                let tag = try Argon2.hash(
                    password: bytes(hex: vector.password),
                    salt: bytes(hex: vector.salt),
                    secret: bytes(hex: vector.secret),
                    associatedData: bytes(hex: vector.associatedData),
                    parameters: parameters,
                    threads: threads,
                    backend: backend
                )
                #expect(
                    hex(tag) == vector.tag,
                    "\(vector.variant) m \(vector.memoryKiB) p \(vector.lanes) threads \(threads)"
                )
            }
        }
    }

    @Test(arguments: backends)
    func `each backend's G matches the scalar one on random blocks, with and without the xor`(backend: CryptoBackend) {
        var generator = SeededRNG(seed: 0x9106)
        for _ in 0 ..< 200 {
            let prev = (0 ..< 128).map { _ in generator.next() }
            let ref = (0 ..< 128).map { _ in generator.next() }
            let start = (0 ..< 128).map { _ in generator.next() }
            for withXor: Int32 in [0, 1] {
                var expected = start
                var actual = start
                adf_argon2_block(&expected, prev, ref, withXor, CryptoBackend.scalar.rawValue)
                adf_argon2_block(&actual, prev, ref, withXor, backend.rawValue)
                #expect(actual == expected)
            }
        }
    }

    @Test(arguments: backends)
    func `each backend's BLAKE2b matches Python's hashlib`(backend: CryptoBackend) throws {
        for vector in ReferenceVectors.blake2b {
            let digest = try BLAKE2b.hash(
                bytes(hex: vector.data),
                length: vector.length,
                key: bytes(hex: vector.key),
                backend: backend
            )
            #expect(hex(digest) == vector.digest)
        }
    }

    @Test
    func `a backend this CPU lacks runs as one it has, and the fastest is the best it has`() {
        #if arch(arm64)
            #expect(CryptoBackend.fastest.resolved == .neonSHA3)
            #expect(CryptoBackend.avx2.resolved == .scalar)
            #expect(!CryptoBackend.ssse3.isAvailable)
        #elseif arch(x86_64)
            #expect(
                CryptoBackend.neonSHA3.resolved == CryptoBackend.fastest.resolved || !CryptoBackend.neonSHA3.isAvailable
            )
        #endif
        #expect(CryptoBackend.scalar.isAvailable)
    }
}

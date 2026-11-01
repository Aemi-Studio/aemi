import Testing

@testable import AemiArgon2

@Suite
struct Argon2Tests {
    /// RFC 9106, section 5: 32 KiB, 3 passes, 4 lanes, a 32-byte tag, every input given.
    @Test(arguments: [
        (Argon2.Variant.d, "512b391b6f1162975371d30919734294f868e3be3984f3c1a13a4db9fabe4acb"),
        (.i, "c814d9d1dc7f37aa13f0d77f2494bda1c8de6b016dd388d29952a4c4672b6ce8"),
        (.id, "0d640df58d78766c08c037a34a8b53c9d01ef0452d75b65eb52520e96b01e659")
    ])
    func `RFC 9106's test vectors`(variant: Argon2.Variant, tag: String) throws {
        let parameters = try Argon2.Parameters(variant: variant, memoryKiB: 32, passes: 3, lanes: 4, tagLength: 32)
        let result = try Argon2.hash(
            password: Array(repeating: 1, count: 32),
            salt: Array(repeating: 2, count: 16),
            secret: Array(repeating: 3, count: 8),
            associatedData: Array(repeating: 4, count: 12),
            parameters: parameters
        )
        #expect(hex(result) == tag)
    }

    @Test(arguments: ReferenceVectors.argon2.indices)
    func `each tag matches OpenSSL's, over random parameters and inputs`(index: Int) throws {
        let vector = ReferenceVectors.argon2[index]
        let parameters = try Argon2.Parameters(
            variant: vector.variant,
            memoryKiB: vector.memoryKiB,
            passes: vector.passes,
            lanes: vector.lanes,
            tagLength: vector.tag.count / 2
        )
        let result = try Argon2.hash(
            password: bytes(hex: vector.password),
            salt: bytes(hex: vector.salt),
            secret: bytes(hex: vector.secret),
            associatedData: bytes(hex: vector.associatedData),
            parameters: parameters
        )
        #expect(
            hex(result) == vector.tag,
            "\(vector.variant) m \(vector.memoryKiB) t \(vector.passes) p \(vector.lanes)"
        )
    }

    @Test(arguments: [
        (8, 1, 0, 32, Argon2.Failure.lanesOutOfRange),
        (8, 1, 1 << 24, 32, .lanesOutOfRange),
        (8, 0, 1, 32, .noPasses),
        (15, 1, 2, 32, .memoryBelowEightBlocksPerLane),
        (8, 1, 1, 3, .tagTooShort),
        (Int(UInt32.max) + 1, 1, 1, 32, .memoryTooLarge)
    ])
    func `parameters outside RFC 9106's bounds are refused`(
        memory: Int,
        passes: Int,
        lanes: Int,
        tag: Int,
        failure: Argon2.Failure
    ) {
        #expect(throws: failure) {
            try Argon2.Parameters(variant: .id, memoryKiB: memory, passes: passes, lanes: lanes, tagLength: tag)
        }
    }

    @Test
    func `a salt under 8 bytes is refused`() throws {
        let parameters = try Argon2.Parameters(variant: .id, memoryKiB: 8, passes: 1, lanes: 1, tagLength: 32)
        #expect(throws: Argon2.Failure.saltTooShort) {
            try Argon2.hash(password: [1], salt: Array(repeating: 0, count: 7), parameters: parameters)
        }
    }
}

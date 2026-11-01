import Testing

@testable import AemiArgon2

@Suite
struct ConstantTimeTests {
    @Test
    func `equal bytes are equal, and a difference anywhere is seen`() {
        let base = (0 ..< 64).map { UInt8($0) }
        #expect(ConstantTime.equal(base, base))
        #expect(ConstantTime.equal([], []))
        for index in base.indices {
            for bit in 0 ..< 8 {
                var other = base
                other[index] ^= 1 << bit
                #expect(!ConstantTime.equal(base, other), "byte \(index) bit \(bit)")
            }
        }
        #expect(!ConstantTime.equal(base, Array(base.dropLast())))
    }

    @Test
    func `a wipe leaves zeros`() {
        var secret: [UInt8] = Array(repeating: 0xA5, count: 100)
        ConstantTime.wipe(&secret)
        #expect(secret == Array(repeating: 0, count: 100))
    }

    @Test
    func `verify accepts the password's tag and refuses another's`() throws {
        let parameters = try Argon2.Parameters(variant: .id, memoryKiB: 64, passes: 2, lanes: 2, tagLength: 32)
        let salt: [UInt8] = Array(repeating: 7, count: 16)
        let tag = try Argon2.hash(password: Array("right".utf8), salt: salt, parameters: parameters)
        #expect(try Argon2.verify(tag, password: Array("right".utf8), salt: salt, parameters: parameters))
        #expect(try !Argon2.verify(tag, password: Array("wrong".utf8), salt: salt, parameters: parameters))
    }
}

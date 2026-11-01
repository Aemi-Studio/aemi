import Testing

@testable import AemiArgon2

@Suite
struct BLAKE2bTests {
    @Test
    func `RFC 7693's example: BLAKE2b-512 of abc`() throws {
        let digest = try BLAKE2b.hash(Array("abc".utf8), length: 64)
        #expect(
            hex(digest)
                == "ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d1"
                + "7d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923"
        )
    }

    @Test(arguments: ReferenceVectors.blake2b.indices)
    func `each digest matches Python's hashlib, keyed or not, around block edges`(index: Int) throws {
        let vector = ReferenceVectors.blake2b[index]
        let digest = try BLAKE2b.hash(bytes(hex: vector.data), length: vector.length, key: bytes(hex: vector.key))
        #expect(
            hex(digest) == vector.digest,
            "data \(vector.data.count / 2) bytes, key \(vector.key.count / 2), out \(vector.length)"
        )
    }

    @Test
    func `input given in pieces hashes as given whole, cut anywhere`() throws {
        let data = (0 ..< 300).map { UInt8(truncatingIfNeeded: $0 &* 7) }
        let whole = try BLAKE2b.hash(data, length: 64)
        for cut in [0, 1, 64, 127, 128, 129, 200, 256, 299, 300] {
            var hasher = try BLAKE2b(length: 64)
            hasher.update(Array(data[..<cut]))
            hasher.update(Array(data[cut...]))
            #expect(hasher.finalize() == whole, "cut at \(cut)")
        }
    }

    @Test(arguments: [0, 65])
    func `a length outside 1 to 64 is refused`(length: Int) {
        #expect(throws: BLAKE2b.Failure.lengthOutOfRange) { try BLAKE2b.hash([], length: length) }
    }

    @Test
    func `a key over 64 bytes is refused`() {
        #expect(throws: BLAKE2b.Failure.keyTooLong) {
            try BLAKE2b.hash([], length: 32, key: Array(repeating: 1, count: 65))
        }
    }
}

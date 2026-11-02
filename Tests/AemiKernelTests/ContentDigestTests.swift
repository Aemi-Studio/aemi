import Testing

@testable import AemiKernel

private func hex(_ bytes: [UInt8]) -> String { String(decoding: Hex.encode(bytes), as: UTF8.self) }

@Suite struct ContentDigestTests {
    /// FIPS 180-4 examples and the NIST CAVP short and long messages.
    static let vectors: [(String, String)] = [
        ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
        ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
        (
            "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        ),
        (
            "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu",
            "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1"
        )
    ]

    @Test func `the digest matches the published vectors, on both implementations`() {
        for (message, digest) in Self.vectors {
            #expect(ContentDigest.sha256Hex(Array(message.utf8)) == digest, "\(message)")
            var portable = PortableSHA256()
            portable.update(Array(message.utf8)[...])
            #expect(hex(portable.finalize()) == digest, "\(message)")
        }
    }

    @Test func `a million a's`() {
        let million = [UInt8](repeating: UInt8(ascii: "a"), count: 1_000_000)
        let expected = "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
        #expect(ContentDigest.sha256Hex(million) == expected)
        var portable = PortableSHA256()
        portable.update(million[...])
        #expect(hex(portable.finalize()) == expected)
    }

    @Test func `pieces of any size give the one-shot digest, and the implementations agree on random inputs`() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0 ..< 200 {
            let count = Int.random(in: 0 ... 700, using: &generator)
            let bytes = (0 ..< count).map { _ in UInt8.random(in: 0 ... 255, using: &generator) }
            let whole = ContentDigest.sha256(bytes)
            var hasher = ContentDigest.SHA256()
            var portable = PortableSHA256()
            var index = 0
            while index < count {
                let take = min(count - index, Int.random(in: 1 ... 130, using: &generator))
                hasher.update(bytes[index ..< index + take])
                portable.update(bytes[index ..< index + take])
                index += take
            }
            #expect(hasher.finalize() == whole)
            #expect(portable.finalize() == whole)
            #expect(ContentDigest.sha256(bytes[...]) == whole)
        }
    }
}

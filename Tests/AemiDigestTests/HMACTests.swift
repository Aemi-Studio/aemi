import AemiDigest
import Testing

@Suite struct HMACTests {
    /// RFC 4231 Test Cases 1 and 2.
    @Test func `HMAC-SHA256 matches RFC 4231 test vectors`() {
        let key1 = [UInt8](repeating: 0x0b, count: 20)
        let msg1 = Array("Hi There".utf8)
        let expected1 = "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"
        #expect(ContentDigest.hmacSHA256Hex(key: key1, message: msg1) == expected1)
        #expect(ContentDigest.verifyHMACSHA256Hex(expected1, key: key1, message: msg1))
        #expect(!ContentDigest.verifyHMACSHA256Hex("0" + String(expected1.dropFirst()), key: key1, message: msg1))

        let key2 = Array("Jefe".utf8)
        let msg2 = Array("what do ya want for nothing?".utf8)
        let expected2 = "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
        #expect(ContentDigest.hmacSHA256Hex(key: key2, message: msg2) == expected2)
        #expect(ContentDigest.verifyHMACSHA256Hex(expected2, key: key2, message: msg2))
    }

    @Test func `constantTimeEqual handles equal, unequal, and different lengths`() {
        #expect(ContentDigest.constantTimeEqual([1, 2, 3], [1, 2, 3]))
        #expect(!ContentDigest.constantTimeEqual([1, 2, 3], [1, 2, 4]))
        #expect(!ContentDigest.constantTimeEqual([1, 2, 3], [1, 2]))
    }
}

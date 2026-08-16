import AemiKernel
import Testing

struct UTF8DecodeTests {
    private func decode(_ bytes: [UInt8], at i: Int = 0) -> (value: UInt32, width: Int) {
        UTF8Decode.scalar(bytes, at: i, count: bytes.count)
    }

    @Test func asciiByteIsOneWide() {
        #expect(decode([0x41]) == (0x41, 1))
        #expect(decode([0x00]) == (0x00, 1))
        #expect(decode([0x7F]) == (0x7F, 1))
    }

    @Test func twoByteSequence() {
        // U+00E9 'é' = C3 A9
        #expect(decode([0xC3, 0xA9]) == (0x0000_00E9, 2))
    }

    @Test func threeByteSequence() {
        // U+20AC '€' = E2 82 AC
        #expect(decode([0xE2, 0x82, 0xAC]) == (0x0000_20AC, 3))
    }

    @Test func fourByteSequence() {
        // U+1F600 '😀' = F0 9F 98 80
        #expect(decode([0xF0, 0x9F, 0x98, 0x80]) == (0x0001_F600, 4))
    }

    @Test func truncatedSequenceYieldsReplacement() {
        #expect(decode([0xC3]) == (0xFFFD, 1))  // 2-byte lead, no continuation
        #expect(decode([0xE2, 0x82]) == (0xFFFD, 1))  // 3-byte lead, one short
        #expect(decode([0xF0, 0x9F, 0x98]) == (0xFFFD, 1))  // 4-byte lead, one short
    }

    @Test func invalidLeadOrContinuationYieldsReplacement() {
        #expect(decode([0x80]) == (0xFFFD, 1))  // bare continuation byte
        #expect(decode([0xF8]) == (0xFFFD, 1))  // 5-byte form (invalid lead)
        #expect(decode([0xFF]) == (0xFFFD, 1))
    }

    @Test func decodesAtOffsetWithinWindow() {
        let bytes: [UInt8] = [0x41, 0xC3, 0xA9, 0x42]
        #expect(UTF8Decode.scalar(bytes, at: 1, count: bytes.count) == (0x0000_00E9, 2))
        #expect(UTF8Decode.scalar(bytes, at: 3, count: bytes.count) == (0x42, 1))
    }
}

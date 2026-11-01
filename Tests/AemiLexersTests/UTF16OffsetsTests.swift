import AemiTestKit
import Testing

@testable import AemiLexers

/// Moving byte offsets to UTF-16 ones, and the ASCII-run skip it rests on; moved from Atelier with the type.
struct UTF16OffsetsTests {
    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `a walk in steps counts the utf16 length of the text before each stop`() {
        let characters = ["a", " ", "é", "✓", "変", "🙂", "𝔘", "\r\n"]
        var random = SeededRNG(seed: 0x10)
        for _ in 0 ..< 500 {
            let text = (0 ..< Int(random.next() % 48)).map { _ in characters[Int(random.next() % 8)] }.joined()
            let bytes = Array(text.utf8)
            var stops: [Int] = [0]
            for character in text { stops.append(stops[stops.count - 1] + character.utf8.count) }
            var byte = 0
            var unit = 0
            var stop = 0
            while stop < stops.count - 1 {
                stop = min(stop + 1 + Int(random.next() % 12), stops.count - 1)
                UTF16Offsets.advance(&byte, to: stops[stop], in: bytes.span, counting: &unit)
                #expect(byte == stops[stop])
                #expect(unit == String(decoding: bytes[..<stops[stop]], as: UTF8.self).utf16.count, "\(text)")
            }
        }
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `eight bytes at a time count what one byte at a time does, on any bytes`() {
        var random = SeededRNG(seed: 0xFF)
        for _ in 0 ..< 500 {
            let bytes = (0 ..< Int(random.next() % 40)).map { _ in UInt8(truncatingIfNeeded: random.next()) }
            let start = bytes.isEmpty ? 0 : Int(random.next() % UInt64(bytes.count))
            var byte = start
            var unit = 0
            UTF16Offsets.advance(&byte, to: bytes.count, in: bytes.span, counting: &unit)
            let expected = bytes[start...].reduce(0) { $0 + ($1 & 0xC0 == 0x80 ? 0 : 1) + ($1 >= 0xF0 ? 1 : 0) }
            #expect(byte == bytes.count)
            #expect(unit == expected, "\(bytes) from \(start)")
        }
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `the first non ASCII byte is found past eight byte words and in the tail`() {
        let text = Array("abcdefghijklmnopqrs é".utf8)
        #expect(UTF16Offsets.firstNonASCII(in: text.span, from: 0) == 20)
        #expect(UTF16Offsets.firstNonASCII(in: text.span, from: 20) == 20)
        #expect(UTF16Offsets.firstNonASCII(in: text.span, from: 22) == 22)
        let ascii = Array("abcdefghijk".utf8)
        #expect(UTF16Offsets.firstNonASCII(in: ascii.span, from: 1) == ascii.count)
        for offset in 0 ..< 17 {
            var bytes = [UInt8](repeating: UInt8(ascii: "x"), count: 17)
            bytes[offset] = 0xC3
            #expect(UTF16Offsets.firstNonASCII(in: bytes.span, from: 0) == offset)
        }
    }
}

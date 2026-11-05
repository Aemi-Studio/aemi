import AemiTestKit
import AemiText
import Testing

/// `LineIndex` against a line-by-line count, for both kinds of breaks, over inputs dense in LF, CR, CRLF and two-byte
/// characters, long enough to cross the kernel's 64-byte steps.
struct LineIndexTests {
    @Test func `every offset agrees with a line-by-line count`() {
        var generator = SeededRNG(seed: 0x11E5)
        let alphabet: [UInt8] = [0x61, 0x0A, 0x0D, 0x20, 0xC3, 0xA9]
        for _ in 0 ..< 400 {
            let bytes = (0 ..< generator.int(200)).map { _ in alphabet[generator.int(alphabet.count)] }
            for breaks in [LineIndex.Breaks.lineFeed, .lineFeedOrReturn] {
                let index = LineIndex(bytes, breaks: breaks)
                var line = 1
                var start = 0
                for offset in 0 ... bytes.count {
                    let location = index.location(of: offset)
                    #expect(location.line == line && location.byteColumn == offset - start + 1)
                    guard offset < bytes.count else { break }
                    let crlf = bytes[offset] == 0x0D && offset + 1 < bytes.count && bytes[offset + 1] == 0x0A
                    if bytes[offset] == 0x0A || (bytes[offset] == 0x0D && !crlf && breaks == .lineFeedOrReturn) {
                        line += 1
                        start = offset + 1
                    }
                }
                #expect(index.lineCount == line)
            }
        }
    }

    @Test func `columns count scalars, offsets clamp, an empty buffer has one line`() {
        let index = LineIndex(Array("é: ü\nx".utf8), breaks: .lineFeed)
        #expect(index.location(of: 4).column == 4)
        #expect(index.location(of: 4).byteColumn == 5)
        #expect(index.location(of: 99).description == "2:2")
        #expect(index.location(of: -3).offset == 0)
        #expect(LineIndex([], breaks: .lineFeedOrReturn).lineCount == 1)
        #expect(index.start(ofLine: 1) == 7)
    }
}

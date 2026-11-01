import Testing

@testable import AemiLexers

/// The UTF-16 entry point scans the units' UTF-8 and reports offsets in the units themselves.
struct UTF16EntryTests {
    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `an unpaired surrogate keeps the offsets after it in units`() {
        let units: [UInt16] = [0xDC00, 0x20, 0xD800] + Array(" let x = 1".utf16)
        let tokens = SyntaxHighlighter.tokens(utf16: units, language: .swift)
        #expect(tokens == [lexical(.keyword, 4 ..< 7), lexical(.number, 12 ..< 13)])
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `a surrogate pair counts two units`() {
        let units = Array("\"🙂\" let x = 1".utf16)
        let tokens = SyntaxHighlighter.tokens(utf16: units, language: .swift)
        #expect(
            tokens == [
                lexical(.string, 0 ..< 4), lexical(.keyword, 5 ..< 8),
                lexical(.number, 13 ..< 14)
            ]
        )
    }
}

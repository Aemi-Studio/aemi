import AemiLexers
import Testing

/// The scanners build the token their clients keep, a ``HighlightToken`` in the lexical layer, so no client maps one
/// token type onto another.
struct HighlightTokenTests {
    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `a whole-text scan gives lexical highlight tokens`() {
        let tokens: [HighlightToken] = SyntaxHighlighter.tokens(utf8: Array("let x = 1 // c".utf8), language: .swift)

        #expect(
            tokens == [
                HighlightToken(byteRange: 0 ..< 3, role: .keyword, layer: .lexical),
                HighlightToken(byteRange: 8 ..< 9, role: .number, layer: .lexical),
                HighlightToken(byteRange: 10 ..< 14, role: .comment, layer: .lexical)
            ])
        #expect(tokens.allSatisfy { $0.modifiers.isEmpty && $0.priority == 0 })
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `the UTF-16 entry moves the range and keeps the role and layer`() {
        let tokens = SyntaxHighlighter.tokens(in: "\"é\" let", language: .swift)

        #expect(
            tokens == [
                HighlightToken(byteRange: 0 ..< 3, role: .string, layer: .lexical),
                HighlightToken(byteRange: 4 ..< 7, role: .keyword, layer: .lexical)
            ])
    }

    @Test
    func `layers rank lexical lowest and semantic highest`() {
        #expect(HighlightLayer.lexical < .structural && HighlightLayer.structural < .syntactic)
        #expect(HighlightLayer.syntactic < .semantic)
    }
}

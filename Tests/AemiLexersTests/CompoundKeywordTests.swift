import Testing

@testable import AemiLexers

/// Keywords the word scan cannot see on its own: ones holding a byte that ends a word, and a block comment that starts
/// with the line comment's marker.
struct CompoundKeywordTests {
    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    private func tokens(_ text: String, _ language: Language) -> [HighlightToken] {
        SyntaxHighlighter.tokens(utf8: Array(text.utf8), language: language)
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `ruby's defined? is one keyword`() {
        #expect(tokens("x = defined?(y)", .ruby).contains(lexical(.keyword, 4 ..< 12)))
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `java's non-sealed is one keyword`() {
        #expect(tokens("non-sealed class A {}", .java).first == lexical(.keyword, 0 ..< 10))
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `a word running on past a compound keyword is not one`() {
        #expect(!tokens("defined?x", .ruby).contains { $0.role == .keyword })
        #expect(!tokens("non-sealedness", .java).contains { $0.role == .keyword })
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `a compound keyword at the end of the text is still one`() {
        #expect(tokens("defined?", .ruby) == [lexical(.keyword, 0 ..< 8)])
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `lua's block comment spans its lines`() {
        #expect(tokens("--[[ one\ntwo ]] x = 1", .lua).first == lexical(.comment, 0 ..< 15))
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `lua's line comment still ends its line`() {
        #expect(tokens("-- one\nx = 1", .lua).first == lexical(.comment, 0 ..< 6))
    }
}

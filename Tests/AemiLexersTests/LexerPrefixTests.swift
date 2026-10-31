import Testing

@testable import AemiLexers

extension LexerCorpusTests {
    /// Every prefix of a corpus scans without trapping, and each token lies within the prefix, is not empty, and starts
    /// at or after the one before. Cutting the bytes at every length leaves strings, comments and raw strings open at
    /// the end of input and splits multi-byte characters, which the checksums never reach. It runs with the corpus
    /// tests, serialized, because its allocations would reach the allocation tests' process-wide count.
    struct Prefixes {
        @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
        @Test(arguments: Language.allCases.filter { $0 != .plain })
        func `every prefix scans in bounds`(_ language: Language) {
            let bytes = Array(LexerCorpus.text(language, fragments: 40).utf8)
            for end in 0 ... bytes.count {
                var last = 0
                for token in SyntaxHighlighter.tokens(utf8: Array(bytes[..<end]), language: language) {
                    #expect(
                        token.range.lowerBound >= last && !token.range.isEmpty && token.range.upperBound <= end,
                        "\(language) prefix of \(end) bytes: \(token.range)")
                    last = token.range.upperBound
                }
            }
        }
    }
}

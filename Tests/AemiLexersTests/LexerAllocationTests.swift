import AemiTestKit
import Testing

@testable import AemiLexers

/// The allocation bound describes the optimized lexer. An unoptimized build allocates once per token.
private let isDebugBuild: Bool = {
    #if DEBUG
        true
    #else
        false
    #endif
}()

extension LexerCorpusTests {
    /// A scan allocates its token array and little else, whatever the size of the source: no string, set or array per
    /// token or per keyword candidate.
    struct Allocations {
        @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
        @Test(
            .enabled(if: allocationCountingAvailable && !isDebugBuild),
            arguments: [Language.swift, .json, .yaml, .toml, .html, .css]
        )
        func `a scan makes a handful of allocations`(language: Language) throws {
            let bytes = Array(LexerCorpus.text(language, fragments: 400).utf8)
            _ = SyntaxHighlighter.tokens(utf8: bytes, language: language)
            // The counter is process-wide and the suites outside this one still run alongside, so a count can only
            // come out high: the lowest of several is the scan's own.
            var counts: [Int] = []
            for _ in 0 ..< 64 {
                guard let count = mallocDelta({ _ = SyntaxHighlighter.tokens(utf8: bytes, language: language) }) else {
                    break
                }
                counts.append(count)
            }
            let fewest = try #require(counts.min())
            #expect(fewest <= 4)
        }
    }
}

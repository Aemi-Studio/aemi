import AemiTestKit
import Foundation
import Testing

@testable import AemiLexers

/// Opt-in throughput of the scanners over both unit types; run with AEMI_LEXER_BENCH=1.
struct LexerBenchmark {
    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AEMI_LEXER_BENCH"] != nil))
    func `scanner throughput per language and unit`() {
        var rng = SeededRNG(seed: 7)
        let fragments: [Language: [String]] = [
            .swift: [
                "let value = compute(x: 1, y: \"é ✓\") // note\n",
                "/// Doc\nfunc f<T: P>(_ t: T) async throws -> [T] { return [t] }\n",
                "@MainActor final class C { var n = 0x1F }\n"
            ],
            .typescript: ["const t: string = `tmpl ${x}`; // c\n", "export class A<T> { private n = 1.5e3 }\n"],
            .json: ["{\"key\": [1, 2.5, true, null, \"é\"], \"n\": -1},\n"],
            .html: ["<div class=\"a\" id='b'>é &amp; text<!-- c --></div>\n"]
        ]
        let clock = ContinuousClock()
        for (language, pieces) in fragments.sorted(by: { $0.key.hashValue < $1.key.hashValue }) {
            var text = ""
            while text.utf8.count < 400_000 { text += rng.pick(pieces) }
            let utf16 = Array(text.utf16)
            let utf8 = Array(text.utf8)
            var start = clock.now
            var count16 = 0
            for _ in 0 ..< 5 { count16 = SyntaxHighlighter.tokens(utf16: utf16, language: language).count }
            let time16 = (clock.now - start) / 5
            start = clock.now
            var count8 = 0
            for _ in 0 ..< 5 { count8 = SyntaxHighlighter.tokens(utf8: utf8, language: language).count }
            let time8 = (clock.now - start) / 5
            #expect(count8 == count16)
            print("BENCH lexer \(language) \(utf8.count / 1000) KB: utf16 \(time16) (\(count16) tokens), utf8 \(time8)")
        }
    }
}

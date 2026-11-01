import Foundation
import Testing

@testable import AemiLexers

/// Opt-in timing of each scanner over a generated corpus of about two megabytes, through the UTF-8 entry
/// point, in a release build: `AEMI_LEXER_BENCH=1 swift test -c release --filter LexerThroughputBenchmark`. The checksum
/// covers every token, so two builds that print the same checksum produce the same tokens.
struct LexerThroughputBenchmark {
    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test(
        .serialized,
        .enabled(if: ProcessInfo.processInfo.environment["AEMI_LEXER_BENCH"] != nil),
        arguments: Language.allCases.filter { $0 != .plain }
    )
    func `scans a generated corpus`(language: Language) {
        var text = ""
        var seed: UInt64 = 1
        while text.utf8.count < 2_000_000 {
            text += LexerCorpus.text(language, seed: seed)
            seed += 1
        }
        let bytes = Array(text.utf8)
        var samples: [Double] = []
        var tokenCount = 0
        var checksum: UInt64 = 14_695_981_039_346_656_037
        for iteration in 0 ..< 23 {
            // Each result is released before the next timed call, so no call pays for freeing another's.
            var tokens: [HighlightToken] = []
            let elapsed = ContinuousClock()
                .measure { tokens = SyntaxHighlighter.tokens(utf8: bytes, language: language) }
            if iteration == 0 {
                tokenCount = tokens.count
                for token in tokens {
                    let fields = [
                        UInt64(token.role.rawValue), UInt64(token.byteRange.lowerBound),
                        UInt64(token.byteRange.upperBound)
                    ]
                    for field in fields { checksum = (checksum ^ field) &* 1_099_511_628_211 }
                }
            } else if iteration >= 3 {
                samples.append(
                    Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
                )
            }
        }
        let sorted = samples.sorted()
        let rounded = sorted.map { ($0 * 1_000).rounded() / 1_000 }
        print(
            "BENCH lexer \(language) bytes \(bytes.count) tokens \(tokenCount) checksum \(checksum) "
                + "median \(sorted[sorted.count / 2]) ms samples \(rounded)"
        )
    }
}

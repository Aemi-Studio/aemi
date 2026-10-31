import Testing

@testable import AemiLexers

/// The corpus-wide checks, run one at a time: the allocation counter is process-wide, so a corpus scan running beside
/// the allocation test would add its own allocations to the count.
@Suite(.serialized)
struct LexerCorpusTests {}

extension LexerCorpusTests {
    /// The scanners' tokens over generated corpora, pinned to the checksums the array-backed scanners produced on the
    /// same corpora (commit 384d6e1): byte offsets from the UTF-8 entry point, UTF-16 offsets from the string one.
    /// Ruby's and Lua's were pinned again when `defined?` became a keyword and `--[[` a block comment; Swift's, Java's
    /// and C's when an exponent kept its sign (`1.5e-3`, one number instead of two). Those were the only tokens that
    /// changed: with the sign rule off, the old checksums pass.
    struct Checksums {
        struct Pinned: Sendable, CustomTestStringConvertible {
            let language: Language
            let utf8: UInt64
            let utf16: UInt64

            var testDescription: String { "\(language)" }
        }

        private static let pinned = [
            Pinned(language: .swift, utf8: 10_922_954_919_353_625_054, utf16: 14_062_905_838_113_393_744),
            Pinned(language: .json, utf8: 14_520_470_785_721_917_561, utf16: 5_493_500_675_082_135_638),
            Pinned(language: .yaml, utf8: 4_228_406_832_964_909_385, utf16: 5_991_581_733_253_680_065),
            Pinned(language: .toml, utf8: 13_105_711_445_155_761_955, utf16: 823_670_127_544_899_540),
            Pinned(language: .html, utf8: 2_091_709_320_393_639_334, utf16: 7_962_723_397_544_016_813),
            Pinned(language: .css, utf8: 17_426_337_964_316_918_796, utf16: 1_507_747_157_084_478_385),
            Pinned(language: .objectiveC, utf8: 5_458_404_258_900_638_227, utf16: 2_697_578_144_062_634_204),
            Pinned(language: .kotlin, utf8: 15_330_627_633_803_403_623, utf16: 6_581_133_662_376_998_086),
            Pinned(language: .java, utf8: 7_670_727_339_457_196_828, utf16: 8_650_446_189_903_020_363),
            Pinned(language: .javascript, utf8: 15_037_033_709_853_658_989, utf16: 17_041_985_824_231_534_070),
            Pinned(language: .typescript, utf8: 12_146_365_675_809_974_089, utf16: 16_750_581_102_885_416_720),
            Pinned(language: .c, utf8: 1_879_223_757_176_376_926, utf16: 8_214_729_857_555_355_555),
            Pinned(language: .cpp, utf8: 5_531_877_697_839_413_868, utf16: 10_844_020_834_317_175_594),
            Pinned(language: .python, utf8: 17_903_937_812_946_876_530, utf16: 5_699_932_798_052_656_778),
            Pinned(language: .shell, utf8: 3_394_770_876_979_639_657, utf16: 9_757_537_059_008_455_063),
            Pinned(language: .fish, utf8: 17_160_067_375_318_534_466, utf16: 11_894_179_055_712_592_768),
            Pinned(language: .rust, utf8: 7_605_693_228_853_812_802, utf16: 8_598_047_877_825_995_739),
            Pinned(language: .go, utf8: 14_243_606_034_042_225_803, utf16: 7_989_937_377_641_077_313),
            Pinned(language: .ruby, utf8: 1_524_950_182_278_493_854, utf16: 9_183_146_328_383_197_431),
            Pinned(language: .lua, utf8: 16_817_558_350_193_199_188, utf16: 1_630_209_837_564_898_524)
        ]

        @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
        @Test(arguments: pinned)
        func `byte offsets keep the checksum of the array-backed scanners`(_ pinned: Pinned) {
            let text = LexerCorpus.text(pinned.language)
            let tokens = SyntaxHighlighter.tokens(utf8: Array(text.utf8), language: pinned.language)
            #expect(Self.checksum(tokens) == pinned.utf8)
        }

        @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
        @Test(arguments: pinned)
        func `utf16 offsets keep the checksum of the array-backed scanners`(_ pinned: Pinned) {
            let text = LexerCorpus.text(pinned.language)
            let tokens = SyntaxHighlighter.tokens(in: text, language: pinned.language)
            #expect(Self.checksum(tokens) == pinned.utf16)
        }

        @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
        @Test(arguments: pinned)
        func `the utf16 array entry keeps the checksum too`(_ pinned: Pinned) {
            let text = LexerCorpus.text(pinned.language)
            let tokens = SyntaxHighlighter.tokens(utf16: Array(text.utf16), language: pinned.language)
            #expect(Self.checksum(tokens) == pinned.utf16)
        }

        @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
        /// FNV-1a over each token's kind and range.
        private static func checksum(_ tokens: [Token]) -> UInt64 {
            var hash: UInt64 = 14_695_981_039_346_656_037
            for token in tokens {
                let fields = [
                    UInt64(token.kind.ordinal), UInt64(token.range.lowerBound), UInt64(token.range.upperBound)
                ]
                for field in fields { hash = (hash ^ field) &* 1_099_511_628_211 }
            }
            return hash
        }
    }
}

extension TokenKind {
    /// A stable number per kind, for checksums.
    fileprivate var ordinal: Int {
        switch self {
            case .keyword: 1
            case .string: 2
            case .comment: 3
            case .number: 4
            case .type: 5
            case .attribute: 6
            case .tag: 7
            case .attributeName: 8
            case .entity: 9
        }
    }
}

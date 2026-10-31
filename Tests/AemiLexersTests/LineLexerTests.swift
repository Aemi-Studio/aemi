import AemiLexers
import Testing

/// Scanning a line at a time, each line from the state the last one ended in (P1a), gives each line the tokens the
/// whole-text scan gives it.
struct LineLexerTests {
    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    /// Every line of `text` scanned in order from ``LexState/initial``, each line's tokens from its own start.
    static func lineScan(_ text: String, language: Language) -> [[LineToken]] {
        let bytes = Array(text.utf8)
        let lexer = LexicalLineLexer(language: language)
        var state = LexState.initial
        return lineRanges(bytes)
            .map { range in
                var tokens: [LineToken] = []
                state = lexer.scan(bytes.span.extracting(range), from: state, into: &tokens)
                return tokens
            }
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    /// The whole-text scan of `text`, cut at its lines: a token across a line break is cut into one piece a line.
    static func wholeScan(_ text: String, language: Language) -> [[LineToken]] {
        let bytes = Array(text.utf8)
        let tokens = SyntaxHighlighter.tokens(utf8: bytes, language: language)
        var next = 0
        return lineRanges(bytes)
            .map { line in
                // Tokens are ascending and disjoint: skip those ending before the line, take those overlapping it, and
                // keep the last one for the next line when it runs on past this one.
                while next < tokens.count, tokens[next].range.upperBound <= line.lowerBound { next += 1 }
                var cut: [LineToken] = []
                var index = next
                while index < tokens.count, tokens[index].range.lowerBound < line.upperBound {
                    let range = tokens[index].range.clamped(to: line)
                    if !range.isEmpty {
                        cut.append(
                            LineToken(
                                range: range.lowerBound - line.lowerBound ..< range.upperBound - line.lowerBound,
                                role: tokens[index].kind.role))
                    }
                    index += 1
                }
                return cut
            }
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    /// Each line's bytes without its `\n`; a text ending in a line break has an empty last line, as an editor shows.
    static func lineRanges(_ bytes: [UInt8]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start = 0
        for (index, byte) in bytes.enumerated() where byte == UInt8(ascii: "\n") {
            ranges.append(start ..< index)
            start = index + 1
        }
        ranges.append(start ..< bytes.count)
        return ranges
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test(arguments: Language.allCases.filter { $0 != .plain })
    func `a line scan equals the whole-text scan on each language's corpus`(language: Language) {
        // LF line ends: a line lent without its `\r` would read an escape before a CRLF differently.
        let text = LexerCorpus.text(language, fragments: 400).replacing("\r\n", with: "\n")

        #expect(Self.lineScan(text, language: language) == Self.wholeScan(text, language: language))
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test(arguments: [
        (Language.swift, ["let ", "x", "1.5", "/*", "*/", "\"", "\"\"\"", "#\"", "\"#", "\\", " ", "// c", "$0", "\n"]),
        (.python, ["def ", "x", "'", "\"", "'''", "\"\"\"", "\\", "# c", " ", "1", "\n"]),
        (.javascript, ["let ", "`", "${a}", "\"", "'", "/*", "*/", "\\", "//", " ", "\n"]),
        (.lua, ["local ", "--[[", "]]", "--", "\"", "'", "\\", "x", " ", "\n"]),
        (.rust, ["fn ", "/*", "*/", "\"", "'a", "\\", "r", " ", "\n"]),
        (.css, ["a", "{", "}", "b:", "/*", "*/", "\"", "'", "\\", ".c", "#fff", "1px", "//", " ", "\n"]),
        (
            .html,
            [
                "<a", " b=\"", "\"", "'", ">", "/>", "<!--", "-->", "<!x", "<script>", "</script>", "<style>",
                "</style>", "x", "&amp;", " ", "\n"
            ]
        )
    ])
    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    func `a line scan equals the whole-text scan on generated texts`(language: Language, pieces: [String]) {
        var random: UInt64 = 0x1E
        for _ in 0 ..< 400 {
            var text = ""
            for _ in 0 ..< 60 {
                random = random &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                text += pieces[Int(random >> 33) % pieces.count]
            }
            // A final line break: a number that ends a text with a dot keeps the dot in a whole-text scan only.
            text += "\n"

            #expect(
                Self.lineScan(text, language: language) == Self.wholeScan(text, language: language),
                "\(text.debugDescription)")
        }
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `a line inside a block comment or a string starts in its state and is coloured as one`() {
        let text = "a /* one\n/* two */ still\nend */ let x\nlet s = \"\"\"\nbody\n\"\"\"\n"

        let lines = Self.lineScan(text, language: .swift)

        #expect(lines[1].map(\.role) == [.comment])
        #expect(lines[1].map(\.range) == [0 ..< 15])
        #expect(lines[2].map(\.role) == [.comment, .keyword])
        #expect(lines[4].map(\.role) == [.string])
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `a plain text has no tokens and keeps the initial state`() {
        var tokens: [LineToken] = []
        let bytes = Array("/* not a comment".utf8)
        let state = LexicalLineLexer(language: .plain).scan(bytes.span, from: .initial, into: &tokens)

        #expect(tokens.isEmpty)
        #expect(state == .initial)
    }
}

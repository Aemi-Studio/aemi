/// Scans a text a line at a time: each line from the state the line before it ended in, so a line
/// can be scanned again, or first, without the lines before it once their states are known (``LexStates``).
public protocol LineLexer: Sendable {
    /// Scans `line`, without its terminator, from `state`, appending its tokens to `tokens`, ascending and disjoint, in
    /// UTF-8 byte offsets from the line's start.
    /// - Returns: The state the next line starts in.
    func scan(_ line: Span<UInt8>, from state: LexState, into tokens: inout [LineToken]) -> LexState
}

/// The scanners of ``SyntaxHighlighter``, a line at a time.
///
/// Scanning a text's lines in order, each from the state the last one returned, gives each line the tokens
/// the whole-text scan gives it, cut at the line, for a text whose lines end in line breaks. The two differ only
/// where a whole-text scan reads past a line break: a number that ends a text's last line with a dot (`1.`) keeps the
/// dot in a whole-text scan only, and a string that runs across lines is a key in a JSON, YAML or TOML scan only when
/// it closes before a colon or an equals sign, which a line scan learns once the earlier lines are coloured.
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
public struct LexicalLineLexer: LineLexer {
    private enum Scanner: Sendable {
        case code(CodeScanner)
        case markup(HTMLScanner)
        case style(CSSScanner)
        case data(DataScanner)
        case plain
    }

    public let language: Language
    private let scanner: Scanner

    public init(language: Language) {
        self.language = language
        scanner =
            switch language {
                case .swift, .objectiveC, .kotlin, .java, .javascript, .typescript, .c, .cpp, .python, .shell, .fish,
                    .rust, .go, .ruby, .lua, .tla, .lean:
                    .code(CodeScanner(language: language))
                case .html: .markup(HTMLScanner())
                case .css: .style(CSSScanner())
                case .json, .yaml, .toml: .data(DataScanner(format: language))
                case .plain: .plain
            }
    }

    public func scan(_ line: Span<UInt8>, from state: LexState, into tokens: inout [LineToken]) -> LexState {
        switch scanner {
            case .code(let scanner): scanner.scan(line, from: state, endsText: false, into: &tokens)
            case .markup(let scanner): scanner.scan(line, from: state, into: &tokens)
            case .style(let scanner): scanner.scan(line, from: state, into: &tokens)
            case .data(let scanner): scanner.scan(line, from: state, into: &tokens)
            case .plain: .initial
        }
    }
}

extension LineToken: ScannerToken {
    init(kind: TokenKind, range: Range<Int>) {
        self.init(range: range, role: kind.role)
    }
}

/// The scanners' own shorthand for what a token is; each kind stands for one ``HighlightRole``, which every token
/// they build carries.
enum TokenKind: Sendable {
    case keyword
    case string
    case comment
    case number
    case type
    case attribute
    case tag
    case attributeName
    case entity
}

/// What a scanner emits, built in place: ``HighlightToken`` for a whole text, ``LineToken`` for a line, so a client
/// keeps the scanners' tokens as they come.
///
/// Internal on purpose: a generic scan called from another module is not specialized and runs about three times
/// slower (measured 2026-10-31), so the entry points build the clients' token types here, in the module.
protocol ScannerToken {
    init(kind: TokenKind, range: Range<Int>)
}

extension HighlightToken: ScannerToken {
    init(kind: TokenKind, range: Range<Int>) {
        self.init(byteRange: range, role: kind.role, layer: .lexical)
    }
}

/// Hand-written scanners over borrowed UTF-8 bytes. Each scan allocates its token array and nothing per token; the
/// UTF-16 entry points convert the byte offsets once, for callers that index a `String` or a text store.
///
/// From the 26 releases on: the scanners borrow their tables and their callers' arrays as spans, which the standard
/// library offers from those releases.
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
public enum SyntaxHighlighter {
    /// Tokens over `text`, with ranges in UTF-16 offsets.
    /// - Complexity: O(UTF-8 length of `text` + tokens)
    public static func tokens(in text: String, language: Language) -> [HighlightToken] {
        guard language != .plain else { return [] }
        let utf8 = text.utf8Span
        var found = tokens(utf8: utf8.span, language: language)
        if !utf8.isKnownASCII { moveToUTF16(&found, over: utf8.span) }
        return found
    }

    /// Tokens over UTF-16 units, with ranges in UTF-16 offsets. An unpaired surrogate scans as U+FFFD, which takes
    /// one unit as well, so every offset still falls where it does in `units`.
    /// - Complexity: O(`units.count` + tokens)
    public static func tokens(utf16 units: [UInt16], language: Language) -> [HighlightToken] {
        guard language != .plain else { return [] }
        let bytes = utf8(of: units)
        var found = tokens(utf8: bytes.span, language: language)
        if bytes.count != units.count { moveToUTF16(&found, over: bytes.span) }
        return found
    }

    /// The UTF-8 of `units`, with U+FFFD for an unpaired surrogate as `String(decoding:as:)` has, but written directly:
    /// the generic decoder costs about 130 ns a unit.
    private static func utf8(of units: [UInt16]) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(units.count + units.count / 2)
        var index = 0
        while index < units.count {
            let unit = UInt32(units[index])
            index += 1
            if unit < 0x80 {
                bytes.append(UInt8(unit))
            } else if unit < 0x800 {
                bytes.append(UInt8(0xC0 | unit >> 6))
                bytes.append(UInt8(0x80 | unit & 0x3F))
            } else if unit & 0xFC00 == 0xD800, index < units.count, units[index] & 0xFC00 == 0xDC00 {
                let scalar = 0x10000 + (unit - 0xD800) << 10 + (UInt32(units[index]) - 0xDC00)
                index += 1
                bytes.append(UInt8(0xF0 | scalar >> 18))
                bytes.append(UInt8(0x80 | scalar >> 12 & 0x3F))
                bytes.append(UInt8(0x80 | scalar >> 6 & 0x3F))
                bytes.append(UInt8(0x80 | scalar & 0x3F))
            } else {
                let scalar = unit & 0xF800 == 0xD800 ? 0xFFFD : unit
                bytes.append(UInt8(0xE0 | scalar >> 12))
                bytes.append(UInt8(0x80 | scalar >> 6 & 0x3F))
                bytes.append(UInt8(0x80 | scalar & 0x3F))
            }
        }
        return bytes
    }

    /// Tokens over UTF-8 bytes, with ranges in byte offsets.
    /// - Complexity: O(`bytes.count` + tokens)
    public static func tokens(utf8 bytes: [UInt8], language: Language) -> [HighlightToken] {
        tokens(utf8: bytes.span, language: language)
    }

    /// Tokens over borrowed UTF-8 bytes, with ranges in byte offsets.
    /// - Complexity: O(`bytes.count` + tokens)
    public static func tokens(utf8 bytes: Span<UInt8>, language: Language) -> [HighlightToken] {
        scan(utf8: bytes, language: language, as: HighlightToken.self)
    }

    /// The tokens of `bytes` in `language`, built as `Output`, ascending and disjoint, in byte offsets.
    static func scan<Output: ScannerToken>(
        utf8 bytes: Span<UInt8>,
        language: Language,
        as: Output.Type
    ) -> [Output] {
        switch language {
            case .swift, .objectiveC, .kotlin, .java, .javascript, .typescript, .c, .cpp, .python, .shell, .fish,
                .rust, .go, .ruby, .lua, .tla, .lean:
                CodeScanner(language: language).scan(bytes, as: Output.self)
            case .html:
                HTMLScanner().scan(bytes, as: Output.self)
            case .css:
                CSSScanner().scan(bytes, as: Output.self)
            case .json, .yaml, .toml:
                DataScanner(format: language).scan(bytes, as: Output.self)
            case .plain:
                []
        }
    }

    /// Moves `tokens`, ascending and disjoint in byte offsets over `bytes`, to UTF-16 offsets, in one pass over the
    /// bytes up to the last token's end.
    private static func moveToUTF16(_ tokens: inout [HighlightToken], over bytes: Span<UInt8>) {
        var byte = 0
        var unit = 0
        for index in tokens.indices {
            let token = tokens[index]
            UTF16Offsets.advance(&byte, to: token.byteRange.lowerBound, in: bytes, counting: &unit)
            let start = unit
            UTF16Offsets.advance(&byte, to: token.byteRange.upperBound, in: bytes, counting: &unit)
            tokens[index] = HighlightToken(byteRange: start ..< unit, role: token.role, layer: token.layer)
        }
    }
}

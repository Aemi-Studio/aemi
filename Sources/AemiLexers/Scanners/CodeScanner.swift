/// Scans the code languages over borrowed UTF-8 bytes, driven by a `LanguageSyntax`: keywords, capitalized types,
/// numbers, strings, comments and attribute words. A table of byte classes sends each byte down its path, and a
/// keyword is looked up only when a keyword of its length starts with its first byte, so a scan allocates nothing
/// but its token array.
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
struct CodeScanner {
    private let tables: Tables

    init(language: Language) {
        tables = Tables.all.first { $0.language == language } ?? Tables(language: language)
    }

    /// The tokens of `units`, ascending and disjoint, with byte offsets.
    /// - Complexity: O(`units.count`)
    func scan<Output: ScannerToken>(_ units: Span<UInt8>, as: Output.Type) -> [Output] {
        var tokens: [Output] = []
        tokens.reserveCapacity(units.count / 16 + 16)
        _ = scan(units, from: .initial, endsText: true, into: &tokens)
        return tokens
    }

    /// Appends the tokens of `units`, scanned from `state`, ascending and disjoint, with byte offsets.
    /// - Parameters:
    ///   - units: A whole text, or one line without its terminator, whose end then stands for a line break.
    ///   - state: The state `units` starts in: ``LexState/initial`` for a text, the last line's for a line.
    ///   - endsText: Whether the end of `units` ends the text, which a number ending in a dot tests.
    ///   - tokens: Where the tokens go.
    /// - Returns: The state at the end of `units`: a block comment or a string still open, or plain code.
    /// - Complexity: O(`units.count`)
    func scan<Output: ScannerToken>(
        _ units: Span<UInt8>,
        from state: LexState,
        endsText: Bool,
        into tokens: inout [Output]
    ) -> LexState {
        let classes = tables.classes.span
        let count = units.count
        let (resumed, open) = resume(units, from: state, into: &tokens)
        if let open { return open }
        var index = resumed
        while index < count {
            let unit = units[index]
            let flags = classes[Int(unit)]
            if flags & Class.identifierStart != 0 {
                let start = index
                index += 1
                while index < count, classes[Int(units[index])] & Class.identifier != 0 { index += 1 }
                if tables.prefixedRawStrings, index < count, units[index] == ASCII.quote || units[index] == ASCII.hash,
                    let (kind, end, open) = prefixedRawString(units, wordStart: start, wordEnd: index)
                {
                    if let kind { tokens.append(Output(kind: kind, range: start ..< end)) }
                    if let open { return open }
                    index = end
                } else if !tables.compoundKeywords.isEmpty,
                    let end = compoundKeywordEnd(units, from: start, wordEnd: index)
                {
                    index = end
                    tokens.append(Output(kind: .keyword, range: start ..< index))
                } else if tables.keywords.contains(units, from: start, to: index) {
                    tokens.append(Output(kind: .keyword, range: start ..< index))
                } else if ASCII.isUpper(unit) {
                    tokens.append(Output(kind: .type, range: start ..< index))
                }
            } else if flags & Class.digit != 0 {
                let start = index
                index = numberEnd(units, from: index, classes: classes, endsText: endsText)
                tokens.append(Output(kind: .number, range: start ..< index))
            } else if flags & Class.special != 0 {
                let (kind, range, open) = scanSpecial(units, at: index, classes: classes)
                if let kind { tokens.append(Output(kind: kind, range: range)) }
                if let open { return open }
                index = range.upperBound
            } else {
                index += 1
            }
        }
        return .initial
    }

    /// Ends the construct `state` says `units` starts inside, appending its token: where plain code resumes, or the
    /// state at the end of `units` when the construct runs on past it.
    private func resume<Output: ScannerToken>(
        _ units: Span<UInt8>,
        from state: LexState,
        into tokens: inout [Output]
    ) -> (index: Int, open: LexState?) {
        switch state.mode {
            case .blockComment:
                guard let block = tables.syntax.blockComment else { return (0, nil) }
                let (end, depth) = blockCommentBody(units, from: 0, depth: state.count, block: block)
                if end > 0 { tokens.append(Output(kind: .comment, range: 0 ..< end)) }
                return (end, depth == 0 ? nil : LexState(mode: .blockComment, count: depth))
            case .string:
                let quote = state.quote
                let (end, isOpen) = stringBody(
                    units,
                    from: 0,
                    quote: quote,
                    isTriple: state.isTriple,
                    hashes: state.count,
                    isRaw: state.isRaw
                )
                if end > 0 { tokens.append(Output(kind: .string, range: 0 ..< end)) }
                return (end, isOpen ? state : nil)
            case .longString:
                let (end, isOpen) = longStringBody(units, from: 0, level: state.count)
                if end > 0 { tokens.append(Output(kind: .string, range: 0 ..< end)) }
                return (end, isOpen ? state : nil)
            default:
                return (0, nil)
        }
    }

    /// What the special byte at `index` starts, tried in the order the languages need: a raw string, a directive, an
    /// Objective-C string, a comment, a string, a long string, an attribute or a variable. Returns the token's kind, nil when the
    /// byte starts none, the range to skip, which ends where scanning resumes, and the state at the end of `units`
    /// when the token runs on past it.
    private func scanSpecial(
        _ units: Span<UInt8>,
        at index: Int,
        classes: Span<UInt8>
    ) -> (kind: TokenKind?, range: Range<Int>, open: LexState?) {
        let unit = units[index]
        let next = index + 1 < units.count ? units[index + 1] : 0
        let nextStartsWord = classes[Int(next)] & Class.identifierStart != 0
        if tables.rawStrings, unit == ASCII.hash {
            var quote = index
            while quote < units.count, units[quote] == ASCII.hash { quote += 1 }
            guard quote < units.count, units[quote] == ASCII.quote else { return (nil, index ..< quote, nil) }
            let (end, open) = stringEnd(units, from: quote, quote: ASCII.quote, hashes: quote - index)
            return (.string, index ..< end, open)
        }
        let syntax = tables.syntax
        if syntax.hasPreprocessor, unit == ASCII.hash, nextStartsWord {
            return (.attribute, index ..< wordEnd(units, from: index + 1, classes: classes), nil)
        }
        if syntax.hasPreprocessor, unit == ASCII.at, classes[Int(next)] & Class.quote != 0 {
            let (end, open) = stringEnd(units, from: index + 1, quote: next, hashes: 0)
            return (.string, index ..< end, open)
        }
        // A block comment first: Lua's `--[[` starts with its line comment's `--`.
        if let block = syntax.blockComment, matches(block.start, in: units, at: index) {
            let (end, depth) = blockCommentBody(units, from: index + block.start.count, depth: 1, block: block)
            return (.comment, index ..< end, depth > 0 ? LexState(mode: .blockComment, count: depth) : nil)
        }
        // Indexed: iterating an array of arrays allocates on every step of an unoptimized build.
        var comment = 0
        while comment < syntax.lineComments.count {
            let pattern = syntax.lineComments[comment]
            comment += 1
            guard matches(pattern, in: units, at: index) else { continue }
            var end = index + pattern.count
            while end < units.count, units[end] != ASCII.newline { end += 1 }
            return (.comment, index ..< end, nil)
        }
        if classes[Int(unit)] & Class.quote != 0 {
            let (end, open) = stringEnd(units, from: index, quote: unit, hashes: 0)
            return (.string, index ..< end, open)
        }
        if syntax.hasLongStrings, unit == ASCII.openBracket {
            var bracket = index + 1
            while bracket < units.count, units[bracket] == ASCII.equals { bracket += 1 }
            guard bracket < units.count, units[bracket] == ASCII.openBracket else {
                return (nil, index ..< bracket, nil)
            }
            let level = bracket - index - 1
            let (end, isOpen) = longStringBody(units, from: bracket + 1, level: level)
            return (.string, index ..< end, isOpen ? LexState(mode: .longString, count: level) : nil)
        }
        if syntax.hasAnnotations, unit == ASCII.at, nextStartsWord {
            return (.attribute, index ..< wordEnd(units, from: index + 1, classes: classes), nil)
        }
        if syntax.hasVariables, unit == ASCII.dollar, nextStartsWord || next == ASCII.openBrace {
            return (.attribute, index ..< variableEnd(units, from: index, classes: classes), nil)
        }
        return (nil, index ..< index + 1, nil)
    }

    /// The end of the compound keyword spelled from `start`, whose word part ends at `wordEnd`, such as Ruby's
    /// `defined?` or Java's `non-sealed`; nil when none is, or when an identifier byte follows it.
    private func compoundKeywordEnd(_ units: Span<UInt8>, from start: Int, wordEnd: Int) -> Int? {
        var index = 0
        while index < tables.compoundKeywords.count {
            let keyword = tables.compoundKeywords[index]
            index += 1
            let end = start + keyword.count
            guard end > wordEnd, matches(keyword, in: units, at: start) else { continue }
            guard end == units.count || !ASCII.isIdentifier(units[end]) else { continue }
            return end
        }
        return nil
    }

    private func matches(_ pattern: [UInt8], in units: Span<UInt8>, at index: Int) -> Bool {
        guard pattern.count <= units.count - index else { return false }
        var offset = 0
        while offset < pattern.count {
            guard units[index + offset] == pattern[offset] else { return false }
            offset += 1
        }
        return true
    }

    /// The end of the identifier characters from `index`.
    private func wordEnd(_ units: Span<UInt8>, from index: Int, classes: Span<UInt8>) -> Int {
        var end = index
        while end < units.count, classes[Int(units[end])] & Class.identifier != 0 { end += 1 }
        return end
    }

    /// The end of a number: identifier characters, dots followed by a digit or, when `units` ends the text, ending
    /// it, and an exponent's sign.
    private func numberEnd(_ units: Span<UInt8>, from start: Int, classes: Span<UInt8>, endsText: Bool) -> Int {
        var index = start
        while index < units.count {
            let unit = units[index]
            if classes[Int(unit)] & Class.identifier != 0 {
                index += 1
            } else if unit == ASCII.dot,
                index + 1 < units.count ? classes[Int(units[index + 1])] & Class.digit != 0 : endsText
            {
                index += 1
            } else if unit == ASCII.plus || unit == ASCII.hyphen,
                isExponentSign(units, at: index, numberStart: start, classes: classes)
            {
                index += 1
            } else {
                break
            }
        }
        return index
    }

    /// The end of `$name` or `${…}`, the latter closing at `}` or, unclosed, just past the end of its line.
    private func variableEnd(_ units: Span<UInt8>, from start: Int, classes: Span<UInt8>) -> Int {
        guard start + 1 < units.count, units[start + 1] == ASCII.openBrace else {
            return wordEnd(units, from: start + 1, classes: classes)
        }
        var index = start + 1
        while index < units.count, units[index] != ASCII.closeBrace, units[index] != ASCII.newline { index += 1 }
        return min(index + 1, units.count)
    }

    /// Where a block comment ends when its body resumes at `start` inside `depth` levels of nesting, and the depth left
    /// open at the end of `units`, zero once it closed. Nested when the language nests them.
    private func blockCommentBody(
        _ units: Span<UInt8>,
        from start: Int,
        depth: Int,
        block: (start: [UInt8], end: [UInt8])
    ) -> (end: Int, depth: Int) {
        let nests = tables.syntax.nestsBlockComments
        let opening = block.start[0]
        let closing = block.end[0]
        var index = start
        var depth = depth
        while index < units.count, depth > 0 {
            let unit = units[index]
            if nests, unit == opening, matches(block.start, in: units, at: index) {
                depth += 1
                index += block.start.count
            } else if unit == closing, matches(block.end, in: units, at: index) {
                depth -= 1
                index += block.end.count
            } else {
                index += 1
            }
        }
        return (min(index, units.count), depth)
    }

    /// The end of a string whose opening quote is at `start`, preceded by `hashes` hashes for a raw string, and the
    /// state at the end of `units` when it runs on past it (``stringBody(_:from:quote:isTriple:hashes:)``).
    private func stringEnd(_ units: Span<UInt8>, from start: Int, quote: UInt8, hashes: Int) -> (Int, LexState?) {
        let isTriple =
            tables.classes[Int(quote)] & Class.tripleQuote != 0 && start + 2 < units.count
            && units[start + 1] == quote && units[start + 2] == quote
        let (end, isOpen) = stringBody(
            units,
            from: start + (isTriple ? 3 : 1),
            quote: quote,
            isTriple: isTriple,
            hashes: hashes
        )
        return (end, isOpen ? LexState(mode: .string, quote: quote, isTriple: isTriple, count: hashes) : nil)
    }

    /// Where a string's body that resumes at `start` ends, and whether the string is still open at the end of `units`.
    ///
    /// A raw string closes only at a quote followed by as many hashes, and escapes only with a backslash followed by as
    /// many; a string marked raw, as Rust's `r"…"`, has no escapes at all. A raw, tripled or multi-line quote runs
    /// across lines; any other string stops at the end of its line,
    /// unless an escape takes the line break, as a backslash ending a line does.
    func stringBody(
        _ units: Span<UInt8>,
        from start: Int,
        quote: UInt8,
        isTriple: Bool,
        hashes: Int,
        isRaw: Bool = false
    ) -> (end: Int, isOpen: Bool) {
        let spansLines = isRaw || isTriple || tables.classes[Int(quote)] & Class.multilineQuote != 0
        let quotes = isTriple ? 3 : 1
        var index = start
        while index < units.count {
            let unit = units[index]
            if unit == ASCII.backslash, !isRaw {
                if hashes == 0 {
                    index += 2
                    continue
                }
                var escape = index + 1
                while escape < units.count, escape - index - 1 < hashes, units[escape] == ASCII.hash { escape += 1 }
                if escape - index - 1 == hashes {
                    index = escape + 1
                    continue
                }
            } else if unit == quote {
                if closes(units, at: index, quote: quote, quotes: quotes, hashes: hashes) {
                    return (index + quotes + hashes, false)
                }
            } else if unit == ASCII.newline, !spansLines {
                return (index, false)
            }
            index += 1
        }
        // Past the end, an escape took the line break that ends `units`.
        return (units.count, spansLines || index > units.count)
    }

    /// Whether `quotes` quotes and then `hashes` hashes start at `index`.
    private func closes(_ units: Span<UInt8>, at index: Int, quote: UInt8, quotes: Int, hashes: Int) -> Bool {
        guard quotes + hashes <= units.count - index else { return false }
        for offset in 1 ..< quotes where units[index + offset] != quote { return false }
        for offset in quotes ..< quotes + hashes where units[index + offset] != ASCII.hash { return false }
        return true
    }
}

@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
extension CodeScanner {
    /// The bits of a byte's class.
    fileprivate enum Class {
        static let identifierStart: UInt8 = 1
        static let identifier: UInt8 = 2
        static let digit: UInt8 = 4
        /// Can start a comment, a string, an attribute or a variable: the byte goes through `scanSpecial`.
        static let special: UInt8 = 8
        static let quote: UInt8 = 16
        static let tripleQuote: UInt8 = 32
        static let multilineQuote: UInt8 = 64
    }

    /// A language's syntax as the scanner reads it, built once per language.
    fileprivate struct Tables: Sendable {
        static let all = Language.allCases.map(Tables.init)

        let language: Language
        let syntax: LanguageSyntax
        /// The `Class` bits of each byte value.
        let classes: [UInt8]
        let keywords: KeywordTable
        /// Keywords holding a byte that ends a word, such as Ruby's `defined?` and Java's `non-sealed`: the word scan
        /// stops before that byte, so they are matched from the word's start instead.
        let compoundKeywords: [[UInt8]]
        /// Swift's `#"…"#` raw strings.
        let rawStrings: Bool
        /// Rust's `r"…"` raw strings and `r#word` identifiers, read once here rather than through `syntax` per word.
        let prefixedRawStrings: Bool

        init(language: Language) {
            let syntax = LanguageSyntax.syntax(for: language)
            let rawStrings = language == .swift
            self.language = language
            self.syntax = syntax
            self.rawStrings = rawStrings
            prefixedRawStrings = syntax.hasPrefixedRawStrings
            keywords = KeywordTable(syntax.keywords)
            compoundKeywords = syntax.keywords.sorted().map { Array($0.utf8) }
                .filter { word in
                    word.contains { !ASCII.isIdentifier($0) }
                }
            var classes = [UInt8](repeating: 0, count: 256)
            for value in 0 ..< 256 {
                let byte = UInt8(value)
                var flags: UInt8 = 0
                if ASCII.isIdentifierStart(byte) { flags |= Class.identifierStart | Class.identifier }
                if ASCII.isDigit(byte) { flags |= Class.identifier | Class.digit }
                if syntax.quotes.contains(byte) { flags |= Class.quote | Class.special }
                if syntax.tripleQuotes.contains(byte) { flags |= Class.tripleQuote }
                if syntax.multilineQuotes.contains(byte) { flags |= Class.multilineQuote }
                let startsComment =
                    syntax.lineComments.contains { $0.first == byte } || syntax.blockComment?.start.first == byte
                // `#`, `@` and `$` where the language gives them a meaning: a directive or a raw string, an Objective-C
                // string or an attribute, a variable.
                let isSigil =
                    byte == ASCII.hash && (syntax.hasPreprocessor || rawStrings)
                    || byte == ASCII.at && (syntax.hasPreprocessor || syntax.hasAnnotations)
                    || byte == ASCII.dollar && syntax.hasVariables
                let opensLongString = byte == ASCII.openBracket && syntax.hasLongStrings
                if startsComment || isSigil || opensLongString { flags |= Class.special }
                classes[value] = flags
            }
            self.classes = classes
        }
    }

    /// Keywords of up to sixteen bytes packed into two little-endian words and hashed into open-addressed slots;
    /// longer ones in a list. A lookup packs and hashes only a word whose first byte starts a keyword of its length.
    fileprivate struct KeywordTable: Sendable {
        private struct Slot: Sendable {
            var low: UInt64 = 0
            var high: UInt64 = 0
            /// Zero for an empty slot.
            var length = 0
        }

        /// Bit `n` of `lengths[b]` is set when a keyword of `n` bytes starts with byte `b`; bit 31 stands for 31 or more.
        private let lengths: [UInt32]
        private let slots: [Slot]
        private let longKeywords: [[UInt8]]

        init(_ words: Set<String>) {
            var lengths = [UInt32](repeating: 0, count: 256)
            var capacity = 16
            while capacity < words.count * 2 { capacity *= 2 }
            var slots = [Slot](repeating: Slot(), count: capacity)
            var longKeywords: [[UInt8]] = []
            for word in words.sorted() {
                let bytes = Array(word.utf8)
                guard let first = bytes.first else { continue }
                lengths[Int(first)] |= 1 << UInt32(min(bytes.count, 31))
                guard bytes.count <= 16 else {
                    longKeywords.append(bytes)
                    continue
                }
                let packed = Self.pack(bytes.span, from: 0, to: bytes.count)
                var slot = Self.hash(packed) & (capacity - 1)
                while slots[slot].length != 0 { slot = (slot + 1) & (capacity - 1) }
                slots[slot] = packed
            }
            self.lengths = lengths
            self.slots = slots
            self.longKeywords = longKeywords
        }

        /// Whether the bytes from `start` to `end` spell a keyword.
        func contains(_ units: Span<UInt8>, from start: Int, to end: Int) -> Bool {
            let length = end - start
            guard lengths[Int(units[start])] & 1 << UInt32(min(length, 31)) != 0 else { return false }
            guard length <= 16 else { return containsLong(units, from: start, to: end) }
            let packed = Self.pack(units, from: start, to: end)
            var slot = Self.hash(packed) & (slots.count - 1)
            while slots[slot].length != 0 {
                let candidate = slots[slot]
                if candidate.low == packed.low, candidate.high == packed.high, candidate.length == length {
                    return true
                }
                slot = (slot + 1) & (slots.count - 1)
            }
            return false
        }

        /// Whether the bytes from `start` to `end`, more than sixteen, spell one of the long keywords.
        private func containsLong(_ units: Span<UInt8>, from start: Int, to end: Int) -> Bool {
            var index = 0
            while index < longKeywords.count {
                let keyword = longKeywords[index]
                index += 1
                guard keyword.count == end - start else { continue }
                var offset = 0
                while offset < keyword.count, units[start + offset] == keyword[offset] { offset += 1 }
                if offset == keyword.count { return true }
            }
            return false
        }

        /// The bytes from `start` to `end`, at most sixteen, as two little-endian words.
        private static func pack(_ units: Span<UInt8>, from start: Int, to end: Int) -> Slot {
            var packed = Slot(length: end - start)
            for index in start ..< min(end, start + 8) {
                packed.low |= UInt64(units[index]) << UInt64(8 * (index - start))
            }
            for index in min(end, start + 8) ..< end {
                packed.high |= UInt64(units[index]) << UInt64(8 * (index - start - 8))
            }
            return packed
        }

        private static func hash(_ slot: Slot) -> Int {
            var value = slot.low ^ (slot.high &* 0x9E37_79B9_7F4A_7C15) ^ UInt64(slot.length)
            value ^= value >> 33
            value &*= 0xFF51_AFD7_ED55_8CCD
            value ^= value >> 33
            return Int(truncatingIfNeeded: value)
        }
    }
}

/// Scans CSS and its supersets over borrowed UTF-8 bytes: comments, strings, at-rules, property names inside blocks,
/// numbers with units, hex colours, `!important`, and class or id selectors outside blocks.
struct CSSScanner {
    func scan<Output: ScannerToken>(_ units: Span<UInt8>, as: Output.Type) -> [Output] {
        var tokens: [Output] = []
        tokens.reserveCapacity(units.count / 16 + 16)
        _ = scan(units, from: .initial, into: &tokens)
        return tokens
    }

    /// Appends the tokens of `units`, scanned from `state`, ascending and disjoint, with byte offsets.
    /// - Parameters:
    ///   - units: A whole text, or one line without its terminator, whose end then stands for a line break.
    ///   - state: The state `units` starts in: ``LexState/initial`` for a text, the last line's for a line.
    ///   - tokens: Where the tokens go.
    /// - Returns: The state at the end of `units`: the depth of the blocks open there, and whether a comment or a
    ///   string is open too.
    /// - Complexity: O(`units.count`)
    func scan<Output: ScannerToken>(
        _ units: Span<UInt8>, from state: LexState, into tokens: inout [Output]
    ) -> LexState {
        var depth = state.count
        let (resumed, isOpen) = resume(units, from: state, into: &tokens)
        guard !isOpen else { return state }
        var index = resumed
        while index < units.count {
            let unit = units[index]
            let next = index + 1 < units.count ? units[index + 1] : 0
            if unit == ASCII.slash, next == ASCII.asterisk {
                let (end, isOpen) = blockCommentEnd(units, from: index + 2)
                tokens.append(Output(kind: .comment, range: index ..< end))
                if isOpen { return LexState(mode: .blockComment, count: depth) }
                index = end
            } else if unit == ASCII.slash, next == ASCII.slash {
                index = scanUntilNewline(units, from: index, tokens: &tokens)
            } else if unit == ASCII.quote || unit == ASCII.apostrophe {
                let (end, isOpen) = stringEnd(units, from: index + 1, quote: unit)
                tokens.append(Output(kind: .string, range: index ..< end))
                if isOpen { return LexState(mode: .string, quote: unit, count: depth) }
                index = end
            } else if unit == ASCII.at, ASCII.isIdentifierStart(next) {
                index = scanWord(units, from: index, kind: .attribute, tokens: &tokens)
            } else if unit == ASCII.exclamation, ASCII.isIdentifierStart(next) {
                index = scanWord(units, from: index, kind: .keyword, tokens: &tokens)
            } else if unit == ASCII.hash, ASCII.isIdentifier(next) {
                let kind: TokenKind = isHexColor(units, at: index) ? .number : .type
                index = scanWord(units, from: index, kind: kind, tokens: &tokens)
            } else if unit == ASCII.dot, ASCII.isIdentifierStart(next) || next == ASCII.hyphen {
                index = scanWord(units, from: index, kind: .type, tokens: &tokens)
            } else if ASCII.isDigit(unit) || unit == ASCII.dot && ASCII.isDigit(next)
                || unit == ASCII.hyphen && ASCII.isDigit(next)
            {
                index = scanNumber(units, from: index, tokens: &tokens)
            } else if ASCII.isIdentifierStart(unit) || unit == ASCII.hyphen && ASCII.isIdentifierStart(next) {
                index = scanIdentifier(units, from: index, depth: depth, tokens: &tokens)
            } else {
                if unit == ASCII.openBrace { depth += 1 }
                if unit == ASCII.closeBrace { depth = max(depth - 1, 0) }
                index += 1
            }
        }
        return LexState(mode: .normal, count: depth)
    }

    /// Ends the comment or the string `state` holds open at the start of `units`, if any: where scanning resumes, and
    /// whether it is still open at the end of `units`.
    private func resume<Output: ScannerToken>(
        _ units: Span<UInt8>, from state: LexState, into tokens: inout [Output]
    ) -> (index: Int, isOpen: Bool) {
        let resumed: (end: Int, isOpen: Bool)
        let kind: TokenKind
        switch state.mode {
            case .blockComment:
                resumed = blockCommentEnd(units, from: 0)
                kind = .comment
            case .string:
                resumed = stringEnd(units, from: 0, quote: state.quote)
                kind = .string
            default:
                return (0, false)
        }
        if resumed.end > 0 { tokens.append(Output(kind: kind, range: 0 ..< resumed.end)) }
        return (resumed.end, resumed.isOpen)
    }

    /// `#` followed by 3, 4, 6 or 8 hex digits is a colour; anything else is an id selector.
    private func isHexColor(_ units: Span<UInt8>, at start: Int) -> Bool {
        var index = start + 1
        while index < units.count,
            ASCII.isDigit(units[index]) || (units[index] | 32) >= 97 && (units[index] | 32) <= 102
        { index += 1 }
        switch index - start - 1 {
            case 3, 4, 6, 8: return index >= units.count || !ASCII.isIdentifier(units[index])
            default: return false
        }
    }

    /// Where a block comment whose body resumes at `start` ends, past its `*/`, and whether it is still open at the end
    /// of `units`.
    private func blockCommentEnd(_ units: Span<UInt8>, from start: Int) -> (end: Int, isOpen: Bool) {
        var index = start
        while index + 1 < units.count, !(units[index] == ASCII.asterisk && units[index + 1] == ASCII.slash) {
            index += 1
        }
        guard index + 1 < units.count else { return (units.count, true) }
        return (index + 2, false)
    }

    private func scanUntilNewline<Output: ScannerToken>(
        _ units: Span<UInt8>, from start: Int, tokens: inout [Output]
    ) -> Int {
        var index = start
        while index < units.count, units[index] != ASCII.newline { index += 1 }
        tokens.append(Output(kind: .comment, range: start ..< index))
        return index
    }

    /// Where a quoted string whose body resumes at `start` ends, past its closing quote, and whether it is still open
    /// at the end of `units`. An unterminated string takes the newline that ends it, unless an escape takes it, which
    /// leaves the string open on the next line.
    private func stringEnd(_ units: Span<UInt8>, from start: Int, quote: UInt8) -> (end: Int, isOpen: Bool) {
        var index = start
        while index < units.count, units[index] != quote, units[index] != ASCII.newline {
            index += units[index] == ASCII.backslash ? 2 : 1
        }
        return (min(index + 1, units.count), index > units.count)
    }

    private func scanWord<Output: ScannerToken>(
        _ units: Span<UInt8>, from start: Int, kind: TokenKind, tokens: inout [Output]
    ) -> Int {
        var index = start + 1
        while index < units.count, ASCII.isIdentifier(units[index]) || units[index] == ASCII.hyphen { index += 1 }
        tokens.append(Output(kind: kind, range: start ..< index))
        return index
    }

    private func scanNumber<Output: ScannerToken>(
        _ units: Span<UInt8>, from start: Int, tokens: inout [Output]
    ) -> Int {
        var index = start + 1
        while index < units.count,
            ASCII.isIdentifier(units[index]) || units[index] == ASCII.dot || units[index] == ASCII.percent
        { index += 1 }
        tokens.append(Output(kind: .number, range: start ..< index))
        return index
    }

    /// Inside a block an identifier followed by a colon is a property name; elsewhere plain words stay unstyled.
    private func scanIdentifier<Output: ScannerToken>(
        _ units: Span<UInt8>, from start: Int, depth: Int, tokens: inout [Output]
    ) -> Int {
        var index = start
        while index < units.count, ASCII.isIdentifier(units[index]) || units[index] == ASCII.hyphen { index += 1 }
        var cursor = index
        while cursor < units.count, units[cursor] == 32 { cursor += 1 }
        if depth > 0, cursor < units.count, units[cursor] == ASCII.colon {
            tokens.append(Output(kind: .attributeName, range: start ..< index))
        }
        return index
    }
}

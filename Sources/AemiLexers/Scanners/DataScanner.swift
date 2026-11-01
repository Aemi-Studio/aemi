/// Scans JSON, YAML and TOML over borrowed UTF-8 bytes: keys, strings, numbers, the few literal keywords, comments,
/// tables and anchors.
struct DataScanner {
    let format: Language

    /// The tokens of `units`, ascending and disjoint, with byte offsets.
    /// - Complexity: O(`units.count`)
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
    /// - Returns: The state at the end of `units`: a string still open, or plain data.
    /// - Complexity: O(`units.count`)
    func scan<Output: ScannerToken>(
        _ units: Span<UInt8>,
        from state: LexState,
        into tokens: inout [Output]
    ) -> LexState {
        var index = 0
        if state.mode == .string {
            let (end, isOpen) = quotedEnd(units, from: 0, quote: state.quote, isTriple: state.isTriple)
            if end > 0 {
                let key = !isOpen && isKey(units, endingAt: end)
                tokens.append(Output(kind: key ? .attributeName : .string, range: 0 ..< end))
            }
            guard !isOpen else { return state }
            index = end
        }
        while index < units.count {
            let unit = units[index]
            if format != .json, unit == ASCII.hash, index == 0 || ASCII.isSpace(units[index - 1]) {
                index = scanUntilNewline(units, from: index, kind: .comment, tokens: &tokens)
            } else if format == .toml, unit == ASCII.openBracket, isAtLineStart(units, index) {
                index = scanUntilNewline(units, from: index, kind: .tag, tokens: &tokens)
            } else if format == .yaml, marker(in: units, at: index), isAtLineStart(units, index) {
                index = scanUntilNewline(units, from: index, kind: .keyword, tokens: &tokens)
            } else if format == .yaml,
                unit == ASCII.ampersand || unit == ASCII.asterisk || unit == ASCII.exclamation,
                index + 1 < units.count, !ASCII.isSpace(units[index + 1])
            {
                var end = index + 1
                while end < units.count, !ASCII.isSpace(units[end]), units[end] != ASCII.comma,
                    units[end] != ASCII.closeBracket, units[end] != ASCII.closeBrace
                { end += 1 }
                tokens.append(Output(kind: .attribute, range: index ..< end))
                index = end
            } else if unit == ASCII.quote || unit == ASCII.apostrophe && format != .json {
                let (end, open) = scanQuoted(units, from: index, quote: unit, tokens: &tokens)
                if let open { return open }
                index = end
            } else if ASCII.isDigit(unit)
                || unit == ASCII.hyphen && index + 1 < units.count && ASCII.isDigit(units[index + 1])
            {
                index = scanNumber(units, from: index, tokens: &tokens)
            } else if ASCII.isIdentifierStart(unit) {
                index = scanBareWord(units, from: index, tokens: &tokens)
            } else {
                index += 1
            }
        }
        return .initial
    }

    /// Whether only spaces and tabs precede `index` on its line. Checked only where a TOML table or a YAML document
    /// marker could start, so the indentation is walked once per candidate rather than once per byte.
    private func isAtLineStart(_ units: Span<UInt8>, _ index: Int) -> Bool {
        var cursor = index - 1
        while cursor >= 0, units[cursor] == 32 || units[cursor] == 9 { cursor -= 1 }
        return cursor < 0 || units[cursor] == ASCII.newline
    }

    /// Whether a YAML document marker, `---` or `...`, starts at `index`.
    private func marker(in units: Span<UInt8>, at index: Int) -> Bool {
        guard units.count - index >= 3 else { return false }
        let marker = units[index]
        return (marker == ASCII.hyphen || marker == ASCII.dot)
            && units[index + 1] == marker && units[index + 2] == marker
    }

    /// Whether the next meaningful byte after `index` makes what precedes it a key.
    private func isKey(_ units: Span<UInt8>, endingAt index: Int) -> Bool {
        var cursor = index
        while cursor < units.count, units[cursor] == 32 || units[cursor] == 9 { cursor += 1 }
        guard cursor < units.count else { return false }
        switch format {
            case .json: return units[cursor] == ASCII.colon
            case .toml: return units[cursor] == ASCII.equals || units[cursor] == ASCII.dot
            default:
                return units[cursor] == ASCII.colon && (cursor + 1 >= units.count || ASCII.isSpace(units[cursor + 1]))
        }
    }

    private func scanUntilNewline<Output: ScannerToken>(
        _ units: Span<UInt8>,
        from start: Int,
        kind: TokenKind,
        tokens: inout [Output]
    ) -> Int {
        var index = start
        while index < units.count, units[index] != ASCII.newline { index += 1 }
        tokens.append(Output(kind: kind, range: start ..< index))
        return index
    }

    /// Scans the string whose quote is at `start`; returns where scanning resumes and, when the string runs on past
    /// the end of `units`, the state there.
    private func scanQuoted<Output: ScannerToken>(
        _ units: Span<UInt8>,
        from start: Int,
        quote: UInt8,
        tokens: inout [Output]
    ) -> (Int, LexState?) {
        let isTriple =
            format == .toml && start + 2 < units.count && units[start + 1] == quote && units[start + 2] == quote
        let (end, isOpen) = quotedEnd(units, from: start + (isTriple ? 3 : 1), quote: quote, isTriple: isTriple)
        let key = !isOpen && isKey(units, endingAt: end)
        tokens.append(Output(kind: key ? .attributeName : .string, range: start ..< end))
        return (end, isOpen ? LexState(mode: .string, quote: quote, isTriple: isTriple) : nil)
    }

    /// Where a string's body that resumes at `start` ends, and whether it is still open at the end of `units`: a TOML
    /// tripled string runs across lines, any other stops at its line's end, unless an escape takes the line break.
    private func quotedEnd(
        _ units: Span<UInt8>,
        from start: Int,
        quote: UInt8,
        isTriple: Bool
    ) -> (end: Int, isOpen: Bool) {
        var index = start
        while index < units.count {
            let unit = units[index]
            if unit == ASCII.backslash, quote == ASCII.quote {
                index += 2
                continue
            }
            if isTriple {
                if unit == quote, index + 2 < units.count, units[index + 1] == quote, units[index + 2] == quote {
                    return (index + 3, false)
                }
            } else if unit == quote {
                return (index + 1, false)
            } else if unit == ASCII.newline {
                return (index, false)
            }
            index += 1
        }
        // Past the end, an escape took the line break that ends `units`.
        return (units.count, isTriple || index > units.count)
    }

    private func scanNumber<Output: ScannerToken>(
        _ units: Span<UInt8>,
        from start: Int,
        tokens: inout [Output]
    ) -> Int {
        var index = start + 1
        while index < units.count,
            ASCII.isIdentifier(units[index]) || units[index] == ASCII.dot || units[index] == ASCII.hyphen
                || units[index] == ASCII.colon || units[index] == ASCII.plus
        {
            if units[index] == ASCII.colon, format != .toml { break }
            index += 1
        }
        tokens.append(Output(kind: isKey(units, endingAt: index) ? .attributeName : .number, range: start ..< index))
        return index
    }

    /// A bare word: a key before its separator, a literal such as `true` or `null`, or nothing. A YAML key may hold
    /// spaces when it starts its line, after the indentation and an optional `- `.
    private func scanBareWord<Output: ScannerToken>(
        _ units: Span<UInt8>,
        from start: Int,
        tokens: inout [Output]
    ) -> Int {
        let canContainSpaces = format == .yaml && isBareKeyLine(units, start)
        var index = start
        while index < units.count,
            ASCII.isIdentifier(units[index]) || units[index] == ASCII.hyphen
                || (canContainSpaces && units[index] == 32 && index + 1 < units.count
                    && ASCII.isIdentifier(units[index + 1]))
        {
            index += 1
        }
        if isKey(units, endingAt: index) {
            tokens.append(Output(kind: .attributeName, range: start ..< index))
        } else if Self.isLiteral(units, start ..< index) {
            tokens.append(Output(kind: .keyword, range: start ..< index))
        }
        return index
    }

    /// Whether only indentation and an optional dash precede `start` on its line.
    private func isBareKeyLine(_ units: Span<UInt8>, _ start: Int) -> Bool {
        var cursor = start - 1
        while cursor >= 0, units[cursor] == 32 || units[cursor] == 9 { cursor -= 1 }
        if cursor >= 0, units[cursor] == ASCII.hyphen {
            cursor -= 1
            while cursor >= 0, units[cursor] == 32 || units[cursor] == 9 { cursor -= 1 }
        }
        return cursor < 0 || units[cursor] == ASCII.newline
    }

    /// Whether the word in `range` is one of the literals, such as `true` or `null`. The loops index their arrays:
    /// iterating an array of arrays allocates on every step of an unoptimized build.
    private static func isLiteral(_ units: Span<UInt8>, _ range: Range<Int>) -> Bool {
        var index = 0
        while index < literals.count {
            let literal = literals[index]
            index += 1
            guard literal.count == range.count else { continue }
            var offset = 0
            while offset < literal.count, units[range.lowerBound + offset] == literal[offset] { offset += 1 }
            if offset == literal.count { return true }
        }
        return false
    }

    private static let literals: [[UInt8]] = [
        "true", "false", "null", "yes", "no", "on", "off", "inf", "nan", "True", "False", "Null", "TRUE", "FALSE",
        "NULL"
    ]
    .map { Array($0.utf8) }
}

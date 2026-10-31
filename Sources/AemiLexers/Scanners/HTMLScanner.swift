/// Scans HTML and XML over borrowed UTF-8 bytes: tags, attribute names and values, comments, declarations and
/// entities. The body of a `script` or `style` element is skipped, not scanned.
struct HTMLScanner {
    private static let commentStart = Array("<!--".utf8)
    private static let commentEnd = Array("-->".utf8)
    private static let declarationStart = Array("<!".utf8)
    private static let declarationEnd = Array(">".utf8)
    private static let script = Array("script".utf8)
    private static let style = Array("style".utf8)
    private static let scriptEnd = Array("</script".utf8)
    private static let styleEnd = Array("</style".utf8)

    func scan<Output: ScannerToken>(_ units: Span<UInt8>, as: Output.Type) -> [Output] {
        var tokens: [Output] = []
        tokens.reserveCapacity(units.count / 16 + 16)
        _ = scan(units, from: .initial, into: &tokens)
        return tokens
    }

    /// Appends the tokens of `units`, scanned from `state`, ascending and disjoint, with byte offsets.
    /// - Parameters:
    ///   - units: A whole text, or one line without its terminator.
    ///   - state: The state `units` starts in: ``LexState/initial`` for a text, the last line's for a line.
    ///   - tokens: Where the tokens go.
    /// - Returns: The state at the end of `units`: inside a comment, a declaration, a tag, an attribute value or a
    ///   `script` or `style` body, or in text.
    /// - Complexity: O(`units.count`), times a pattern's length where one is searched for.
    func scan<Output: ScannerToken>(
        _ units: Span<UInt8>, from state: LexState, into tokens: inout [Output]
    ) -> LexState {
        var index = 0
        switch state.mode {
            case .markupComment:
                guard let end = find(Self.commentEnd, in: units, from: 0) else {
                    if !units.isEmpty { tokens.append(Output(kind: .comment, range: 0 ..< units.count)) }
                    return state
                }
                tokens.append(Output(kind: .comment, range: 0 ..< end + 3))
                index = end + 3
            case .declaration:
                guard let end = find(Self.declarationEnd, in: units, from: 0) else {
                    if !units.isEmpty { tokens.append(Output(kind: .keyword, range: 0 ..< units.count)) }
                    return state
                }
                tokens.append(Output(kind: .keyword, range: 0 ..< end + 1))
                index = end + 1
            case .tag:
                let (end, open) = scanAttributes(units, from: 0, kind: state.kind, tokens: &tokens)
                if let open { return open }
                index = end
            case .attributeValue:
                let (valueEnd, valueOpen) = scanValue(
                    units, from: 0, quote: state.quote, kind: state.kind, tokens: &tokens)
                if let valueOpen { return valueOpen }
                let (end, open) = scanAttributes(units, from: valueEnd, kind: state.kind, tokens: &tokens)
                if let open { return open }
                index = end
            case .rawText:
                guard let end = find(Self.rawTextEnd(state.kind), in: units, from: 0) else { return state }
                index = end
            default:
                break
        }
        while index < units.count {
            if units[index] == ASCII.lessThan {
                let (end, open) = scanAngle(units, from: index, tokens: &tokens)
                if let open { return open }
                index = end
            } else if units[index] == ASCII.ampersand {
                index = scanEntity(units, from: index, tokens: &tokens)
            } else {
                index += 1
            }
        }
        return .initial
    }

    /// The pattern that ends the body of an element of `kind`.
    private static func rawTextEnd(_ kind: LexState.ElementKind) -> [UInt8] {
        kind == .style ? styleEnd : scriptEnd
    }

    /// Whether `pattern` starts at `index`. A byte also matches its pattern byte minus 32, which lets an uppercase
    /// letter match a lowercase one; it also lets a few control characters stand for punctuation, as it always has.
    private func matches(_ pattern: [UInt8], in units: Span<UInt8>, at index: Int) -> Bool {
        guard pattern.count <= units.count - index else { return false }
        for offset in pattern.indices {
            let unit = units[index + offset]
            if unit != pattern[offset], unit != pattern[offset] &- 32 { return false }
        }
        return true
    }

    private func find(_ pattern: [UInt8], in units: Span<UInt8>, from index: Int) -> Int? {
        var cursor = index
        while cursor < units.count {
            if matches(pattern, in: units, at: cursor) { return cursor }
            cursor += 1
        }
        return nil
    }

    /// Scans what the `<` at `start` opens; returns where scanning resumes and, when what it opens runs on past the end
    /// of `units`, the state there.
    private func scanAngle<Output: ScannerToken>(
        _ units: Span<UInt8>, from start: Int, tokens: inout [Output]
    ) -> (Int, LexState?) {
        if matches(Self.commentStart, in: units, at: start) {
            guard let end = find(Self.commentEnd, in: units, from: start + 4) else {
                tokens.append(Output(kind: .comment, range: start ..< units.count))
                return (units.count, LexState(mode: .markupComment))
            }
            tokens.append(Output(kind: .comment, range: start ..< end + 3))
            return (end + 3, nil)
        }
        if matches(Self.declarationStart, in: units, at: start) {
            guard let end = find(Self.declarationEnd, in: units, from: start) else {
                tokens.append(Output(kind: .keyword, range: start ..< units.count))
                return (units.count, LexState(mode: .declaration))
            }
            tokens.append(Output(kind: .keyword, range: start ..< end + 1))
            return (end + 1, nil)
        }
        var index = start + 1
        let isClosing = index < units.count && units[index] == ASCII.slash
        if isClosing { index += 1 }
        guard index < units.count, ASCII.isAlpha(units[index]) else { return (start + 1, nil) }

        let nameStart = index
        while index < units.count,
            ASCII.isIdentifier(units[index]) || units[index] == ASCII.hyphen || units[index] == ASCII.colon
        {
            index += 1
        }
        tokens.append(Output(kind: .tag, range: start ..< index))
        let name = nameStart ..< index
        let kind: LexState.ElementKind =
            if isClosing {
                .other
            } else if isName(Self.script, in: units, name) {
                .script
            } else if isName(Self.style, in: units, name) {
                .style
            } else {
                .other
            }
        return scanAttributes(units, from: index, kind: kind, tokens: &tokens)
    }

    /// Whether the tag name in `range` is `name`, in any case.
    private func isName(_ name: [UInt8], in units: Span<UInt8>, _ range: Range<Int>) -> Bool {
        guard range.count == name.count else { return false }
        for offset in name.indices where units[range.lowerBound + offset] | 0x20 != name[offset] { return false }
        return true
    }

    /// Scans a tag's attributes from `start` to the `>` or `/>` that closes it, then skips the body of a `script` or
    /// `style` element; returns where scanning resumes and, when the tag or the body runs on past the end of `units`,
    /// the state there.
    private func scanAttributes<Output: ScannerToken>(
        _ units: Span<UInt8>, from start: Int, kind: LexState.ElementKind, tokens: inout [Output]
    ) -> (Int, LexState?) {
        var index = start
        while index < units.count {
            let unit = units[index]
            if unit == ASCII.greaterThan {
                tokens.append(Output(kind: .tag, range: index ..< (index + 1)))
                return skipBody(units, from: index + 1, kind: kind)
            }
            if unit == ASCII.slash, index + 1 < units.count, units[index + 1] == ASCII.greaterThan {
                tokens.append(Output(kind: .tag, range: index ..< (index + 2)))
                return skipBody(units, from: index + 2, kind: kind)
            }
            if unit == ASCII.quote || unit == ASCII.apostrophe {
                let (end, open) = scanValue(units, from: index + 1, quote: unit, kind: kind, tokens: &tokens)
                if open != nil { return (end, open) }
                index = end
            } else if ASCII.isIdentifierStart(unit) {
                let nameStart = index
                while index < units.count,
                    ASCII.isIdentifier(units[index]) || units[index] == ASCII.hyphen || units[index] == ASCII.colon
                {
                    index += 1
                }
                tokens.append(Output(kind: .attributeName, range: nameStart ..< index))
            } else {
                index += 1
            }
        }
        return (index, LexState(mode: .tag, kind: kind))
    }

    /// Scans an attribute value whose body resumes at `start`, its token taking the opening quote just before `start`
    /// when there is one in `units`; returns where its tag's attributes resume and, when the value runs on past the end
    /// of `units`, the state there.
    private func scanValue<Output: ScannerToken>(
        _ units: Span<UInt8>, from start: Int, quote: UInt8, kind: LexState.ElementKind, tokens: inout [Output]
    ) -> (Int, LexState?) {
        var index = start
        while index < units.count, units[index] != quote { index += 1 }
        let valueStart = max(start - 1, 0)
        guard index < units.count else {
            if units.count > valueStart { tokens.append(Output(kind: .string, range: valueStart ..< units.count)) }
            return (units.count, LexState(mode: .attributeValue, quote: quote, kind: kind))
        }
        tokens.append(Output(kind: .string, range: valueStart ..< index + 1))
        return (index + 1, nil)
    }

    /// Where scanning resumes after a tag closes at `start`: past the body of a `script` or `style` element, at the
    /// tag that closes it, or at `start` for any other element.
    private func skipBody(_ units: Span<UInt8>, from start: Int, kind: LexState.ElementKind) -> (Int, LexState?) {
        guard kind != .other else { return (start, nil) }
        guard let end = find(Self.rawTextEnd(kind), in: units, from: start) else {
            return (units.count, LexState(mode: .rawText, kind: kind))
        }
        return (end, nil)
    }

    private func scanEntity<Output: ScannerToken>(
        _ units: Span<UInt8>, from start: Int, tokens: inout [Output]
    ) -> Int {
        var index = start + 1
        // Entity names are ASCII, which keeps the 12-byte cap the same length in UTF-8 and in UTF-16.
        while index < units.count, index - start < 12,
            ASCII.isAlpha(units[index]) || ASCII.isDigit(units[index]) || units[index] == ASCII.hash
        {
            index += 1
        }
        guard index < units.count, units[index] == ASCII.semicolon, index > start + 1 else { return start + 1 }
        tokens.append(Output(kind: .entity, range: start ..< (index + 1)))
        return index + 1
    }
}

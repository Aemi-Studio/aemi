@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
extension CodeScanner {
    /// Whether the `+` or `-` at `index`, inside the number from `numberStart`, signs an exponent: it follows `e` or
    /// `E` in a decimal number, `p` or `P` in a hexadecimal one, and a digit follows it. C's `0x1e-3` is a subtraction.
    func isExponentSign(_ units: Span<UInt8>, at index: Int, numberStart: Int, classes: Span<UInt8>) -> Bool {
        guard index > numberStart, index + 1 < units.count, ASCII.isDigit(units[index + 1]) else { return false }
        let isHex =
            numberStart + 1 < units.count && units[numberStart] == UInt8(ascii: "0")
            && units[numberStart + 1] | 0x20 == UInt8(ascii: "x")
        let marker = units[index - 1] | 0x20
        return marker == UInt8(ascii: isHex ? "p" : "e")
    }

    /// What Rust's prefixes `r`, `br` and `cr` start after the word that ends at `wordEnd`: a raw string, `r"…"` with
    /// any number of hashes around the quotes and no escapes, or a raw identifier, `r#word`. Returns where the string
    /// or identifier ends and the state at the end of `units` when the string runs past it; nil when the word starts
    /// neither. The kind is nil for an identifier, which takes no token.
    func prefixedRawString(
        _ units: Span<UInt8>, wordStart: Int, wordEnd: Int
    ) -> (kind: TokenKind?, end: Int, open: LexState?)? {
        let length = wordEnd - wordStart
        let last = units[wordEnd - 1]
        guard last == UInt8(ascii: "r"), length == 1 || length == 2 else { return nil }
        if length == 2, units[wordStart] != UInt8(ascii: "b"), units[wordStart] != UInt8(ascii: "c") { return nil }
        var quote = wordEnd
        while quote < units.count, units[quote] == ASCII.hash { quote += 1 }
        let hashes = quote - wordEnd
        guard quote < units.count else { return nil }
        if units[quote] == ASCII.quote {
            let (end, isOpen) = stringBody(
                units, from: quote + 1, quote: ASCII.quote, isTriple: false, hashes: hashes, isRaw: true)
            return (
                .string, end, isOpen ? LexState(mode: .string, quote: ASCII.quote, isRaw: true, count: hashes) : nil
            )
        }
        // `r#type`: an identifier spelled like a keyword, no token.
        guard length == 1, hashes == 1, ASCII.isIdentifierStart(units[quote]) else { return nil }
        var end = quote + 1
        while end < units.count, ASCII.isIdentifier(units[end]) { end += 1 }
        return (nil, end, nil)
    }

    /// Where a long string's body that resumes at `start` ends, past its `]`, `level` equals signs and `]`, and
    /// whether it is still open at the end of `units`. It has no escapes and spans lines.
    func longStringBody(_ units: Span<UInt8>, from start: Int, level: Int) -> (end: Int, isOpen: Bool) {
        var index = start
        while index < units.count {
            if units[index] == ASCII.closeBracket {
                var close = index + 1
                while close < units.count, close - index - 1 < level, units[close] == ASCII.equals { close += 1 }
                if close - index - 1 == level, close < units.count, units[close] == ASCII.closeBracket {
                    return (close + 1, false)
                }
            }
            index += 1
        }
        return (units.count, true)
    }
}

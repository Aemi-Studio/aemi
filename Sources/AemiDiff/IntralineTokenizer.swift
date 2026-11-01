/// How intraline emphasis decides what a "unit of change" is.
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
public enum IntralineGranularity: String, CaseIterable, Sendable, Identifiable {
    /// Individual UTF-16 units; the finest emphasis, but a renamed identifier shows as scattered characters.
    case character
    /// Identifier, number and whitespace runs; every other character stands alone.
    case word
    /// Language tokens from swift-syntax for Swift, a code-aware lexer for other languages.
    case syntax

    public var id: String { rawValue }
}

/// Splits a line into the units the word and syntax tiers compare.
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
public enum IntralineTokenizer {
    /// Splits UTF-16 units into words: identifier runs, whitespace runs, and single punctuation units.
    /// - Complexity: O(units)
    public static func words(_ units: [UInt16]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var index = 0
        while index < units.count {
            let start = index
            let unit = units[index]
            if isWord(unit) {
                while index < units.count, isWord(units[index]) { index += 1 }
            } else if isSpace(unit) {
                while index < units.count, isSpace(units[index]) { index += 1 }
            } else {
                index += 1
            }
            ranges.append(start ..< index)
        }
        return ranges
    }

    /// Words, plus string literals kept whole and `@`/`#`-prefixed directives glued to their name.
    /// - Complexity: O(units)
    public static func codeTokens(_ units: [UInt16]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var index = 0
        while index < units.count {
            let start = index
            let unit = units[index]
            if unit == quote || (unit == at && index + 1 < units.count && units[index + 1] == quote) {
                index += unit == at ? 2 : 1
                while index < units.count, units[index] != quote {
                    index += units[index] == backslash ? 2 : 1
                }
                index = min(index + 1, units.count)
            } else if unit == at || unit == hash, index + 1 < units.count, isWord(units[index + 1]) {
                index += 1
                while index < units.count, isWord(units[index]) { index += 1 }
            } else if isWord(unit) {
                while index < units.count, isWord(units[index]) { index += 1 }
            } else if isSpace(unit) {
                while index < units.count, isSpace(units[index]) { index += 1 }
            } else {
                index += 1
            }
            ranges.append(start ..< index)
        }
        return ranges
    }

    private static let quote = UInt16(34)
    private static let hash = UInt16(35)
    private static let at = UInt16(64)
    private static let backslash = UInt16(92)

    private static func isWord(_ unit: UInt16) -> Bool {
        (unit >= 48 && unit <= 57) || (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122) || unit == 95
            || unit >= 128
    }

    private static func isSpace(_ unit: UInt16) -> Bool {
        unit == 32 || unit == 9
    }
}

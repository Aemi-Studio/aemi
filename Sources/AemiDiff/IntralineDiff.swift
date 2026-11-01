/// Emphasis for a pair of changed lines, at the granularity the viewer asks for.
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
public enum IntralineDiff {
    /// Longest line, in UTF-16 units, for which an intraline diff is attempted.
    public static let maximumLineLength = 2000

    /// Above this share of changed units the whole line reads as replaced and no emphasis is returned.
    public static let maximumChangedShare = 0.5

    /// More ranges than this per side means the lines only share scattered pieces, which is not worth emphasizing.
    public static let maximumRangesPerSide = 4

    /// Ranges, in UTF-16 offsets, of the removed units in `old` and the inserted units in `new`.
    /// - Parameters:
    ///   - old: The removed line.
    ///   - new: The inserted line it is paired with.
    ///   - granularity: The unit the two lines are compared in.
    ///   - oldTokens: Token ranges of `old` for the syntax tier; words are used when absent.
    ///   - newTokens: Token ranges of `new` for the syntax tier; words are used when absent.
    ///   - refiners: Cleanup stages applied to the token-level edit script, in order.
    ///   - maximumUnits: The longest line, in UTF-16 units, worth comparing.
    /// - Returns: nil when the lines are too long or too different for the emphasis to help.
    public static func emphasis(
        old: Substring,
        new: Substring,
        granularity: IntralineGranularity = .character,
        oldTokens: [Range<Int>]? = nil,
        newTokens: [Range<Int>]? = nil,
        refiners: [any IntralineRefining] = [],
        maximumUnits: Int = maximumLineLength
    ) -> (old: [Range<Int>], new: [Range<Int>])? {
        guard old.utf16.count <= maximumUnits, new.utf16.count <= maximumUnits else { return nil }
        return emphasis(
            oldUnits: Array(old.utf16), newUnits: Array(new.utf16), granularity: granularity, oldTokens: oldTokens,
            newTokens: newTokens, refiners: refiners)
    }

    /// ``emphasis(old:new:granularity:oldTokens:newTokens:refiners:maximumUnits:)`` over the lines' UTF-16 units,
    /// whose length the caller has checked.
    static func emphasis(
        oldUnits: [UInt16], newUnits: [UInt16], granularity: IntralineGranularity, oldTokens: [Range<Int>]?,
        newTokens: [Range<Int>]?, refiners: [any IntralineRefining]
    ) -> (old: [Range<Int>], new: [Range<Int>])? {
        // Indentation is never the change worth pointing at: compare past it and shift the ranges back.
        let oldLead = oldUnits.prefix { $0 == 32 || $0 == 9 }.count
        let newLead = newUnits.prefix { $0 == 32 || $0 == 9 }.count
        let oldRanges = ranges(of: oldUnits, granularity: granularity, tokens: oldTokens)
            .compactMap { Self.trimmed($0, lead: oldLead) }
        let newRanges = ranges(of: newUnits, granularity: granularity, tokens: newTokens)
            .compactMap { Self.trimmed($0, lead: newLead) }
        let total = max(oldUnits.count + newUnits.count, 1)
        // Every token holds a unit or more, so any script over them changes at least as many units as the shortest
        // one has edits: once that passes the share, the pair can only read as replaced, and the search stops there.
        let budget = Int(Double(total) * maximumChangedShare)
        // A character is its own token: the units themselves are compared, rather than a slice per unit (perf-core
        // D5); token `i` is unit `lead + i` either way.
        let script =
            granularity == .character
            ? LineDiff.diff(Array(oldUnits[oldLead...]), Array(newUnits[newLead...]), maximumEdits: budget)
            : LineDiff.diff(oldRanges.map { oldUnits[$0] }, newRanges.map { newUnits[$0] }, maximumEdits: budget)
        guard var edits = script else { return nil }
        for refiner in refiners {
            edits = refiner.refine(edits, oldRanges: oldRanges, newRanges: newRanges)
        }

        var oldEmphasis: [Range<Int>] = []
        var newEmphasis: [Range<Int>] = []
        var changed = 0
        for edit in edits {
            switch edit {
                case .equal:
                    continue
                case .delete(let index):
                    oldEmphasis.extend(with: oldRanges[index])
                    changed += oldRanges[index].count
                case .insert(let index):
                    newEmphasis.extend(with: newRanges[index])
                    changed += newRanges[index].count
            }
        }

        guard Double(changed) / Double(total) <= maximumChangedShare,
            oldEmphasis.count <= maximumRangesPerSide, newEmphasis.count <= maximumRangesPerSide
        else { return nil }
        return (oldEmphasis, newEmphasis)
    }

    /// `range` past the indentation, or nil when nothing of it is left.
    private static func trimmed(_ range: Range<Int>, lead: Int) -> Range<Int>? {
        let start = max(range.lowerBound, lead)
        return start < range.upperBound ? start ..< range.upperBound : nil
    }

    private static func ranges(of units: [UInt16], granularity: IntralineGranularity, tokens: [Range<Int>]?) -> [Range<
        Int
    >] {
        switch granularity {
            case .character: (0 ..< units.count).map { $0 ..< ($0 + 1) }
            case .word: IntralineTokenizer.words(units)
            case .syntax: tokens ?? IntralineTokenizer.codeTokens(units)
        }
    }
}

@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
extension [Range<Int>] {
    fileprivate mutating func extend(with range: Range<Int>) {
        if let last, last.upperBound == range.lowerBound {
            self[count - 1] = last.lowerBound ..< range.upperBound
        } else {
            append(range)
        }
    }
}

/// Rows a user revealed around a gap between two hunks.
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
public struct GapExpansion: Sendable, Equatable, Hashable {
    /// Rows revealed after the hunk above the gap.
    public var below: Int
    /// Rows revealed before the hunk below the gap.
    public var above: Int

    public init(below: Int = 0, above: Int = 0) {
        self.below = below
        self.above = above
    }
}

/// Splits a diff into hunks: the changed rows with context around them.
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
public enum HunkLayout {
    /// A hunk of the output with the base hunks it grew from, so a gap keeps its identity when expansions merge
    /// hunks around it.
    public struct Hunk: Sendable, Equatable {
        public let rows: Range<Int>
        /// Indices, among the hunks before any expansion, of the first and last base hunk this one covers.
        public let firstBase: Int
        public let lastBase: Int

        public init(rows: Range<Int>, firstBase: Int, lastBase: Int) {
            self.rows = rows
            self.firstBase = firstBase
            self.lastBase = lastBase
        }
    }

    /// - Parameters:
    ///   - changeRanges: Ascending, disjoint ranges of changed rows.
    ///   - rowCount: Rows in the file; hunks are clipped to it.
    ///   - context: Unchanged rows kept on each side of a change.
    ///   - expansions: Extra rows revealed per gap, keyed by base gap index: gap `i` sits before base hunk `i`, so
    ///     gap `0` precedes the first hunk and gap `baseCount` follows the last one. An expansion stops at the
    ///     neighbouring hunk or the file boundary; hunks that meet are merged.
    /// - Returns: Ascending, disjoint hunks clipped to `0..<rowCount`, plus the number of base hunks.
    /// - Complexity: O(changes)
    public static func layout(
        changeRanges: [Range<Int>],
        rowCount: Int,
        context: Int,
        expansions: [Int: GapExpansion] = [:]
    ) -> (hunks: [Hunk], baseCount: Int) {
        let base = merged(changeRanges.map { padded($0, by: context, rowCount: rowCount) })
        var result: [Hunk] = []
        for (index, hunk) in base.enumerated() {
            let above = expansions[index]?.above ?? 0
            let below = expansions[index + 1]?.below ?? 0
            let floor = index > 0 ? base[index - 1].upperBound : 0
            let ceiling = index + 1 < base.count ? base[index + 1].lowerBound : rowCount
            let rows = max(hunk.lowerBound - above, floor) ..< min(hunk.upperBound + below, ceiling)
            if let last = result.last, rows.lowerBound <= last.rows.upperBound {
                result[result.count - 1] = Hunk(
                    rows: last.rows.lowerBound ..< max(last.rows.upperBound, rows.upperBound),
                    firstBase: last.firstBase, lastBase: index)
            } else {
                result.append(Hunk(rows: rows, firstBase: index, lastBase: index))
            }
        }
        return (result, base.count)
    }

    /// The row ranges only; see `layout(changeRanges:rowCount:context:expansions:)`.
    public static func hunks(
        changeRanges: [Range<Int>],
        rowCount: Int,
        context: Int,
        expansions: [Int: GapExpansion] = [:]
    ) -> [Range<Int>] {
        layout(changeRanges: changeRanges, rowCount: rowCount, context: context, expansions: expansions).hunks
            .map(\.rows)
    }

    private static func padded(_ range: Range<Int>, by context: Int, rowCount: Int) -> Range<Int> {
        max(range.lowerBound - context, 0) ..< min(range.upperBound + context, rowCount)
    }

    private static func merged(_ ranges: [Range<Int>]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        for range in ranges where !range.isEmpty {
            if let last = result.last, range.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound ..< max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }
}

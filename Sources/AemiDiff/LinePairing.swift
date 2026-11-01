/// Which removed line a changed block's added line replaces, so intraline emphasis compares the right two lines.
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
public protocol LinePairing: Sendable {
    /// Pairs for one block of removed and added lines, in order; a pair has at least one side. Indices are into
    /// the arrays given.
    func pairs(removed: [Substring], added: [Substring]) -> [LinePair]
    /// ``pairs(removed:added:)`` within `limits`: a block of more than `limits.maximumPairs` removed × added lines
    /// pairs by position.
    func pairs(removed: [Substring], added: [Substring], limits: DiffLimits) -> [LinePair]
}

@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
extension LinePairing {
    public func pairs(removed: [Substring], added: [Substring], limits: DiffLimits) -> [LinePair] {
        guard removed.count * added.count <= limits.maximumPairs else {
            return PositionalPairing().pairs(removed: removed, added: added)
        }
        return pairs(removed: removed, added: added)
    }
}

@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
public struct LinePair: Sendable, Equatable {
    public let old: Int?
    public let new: Int?

    public init(old: Int?, new: Int?) {
        self.old = old
        self.new = new
    }
}

/// The n-th removed line pairs with the n-th added line; leftovers stand alone.
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
public struct PositionalPairing: LinePairing {
    public init() {}

    public func pairs(removed: [Substring], added: [Substring]) -> [LinePair] {
        (0 ..< max(removed.count, added.count))
            .map { index in
                LinePair(old: index < removed.count ? index : nil, new: index < added.count ? index : nil)
            }
    }
}

/// Pairs lines by how much text they share, keeping order: the maximum-weight matching over similarities above
/// a threshold, so a line inserted in the middle of a rewritten block no longer shifts every pairing below it.
/// Falls back to positional pairing when the block is too large for the quadratic matching.
///
/// A line longer than intraline emphasis compares is nobody's counterpart by similarity (Core S13): its bigrams would
/// cost the most of all, for an emphasis it never gets. It still pairs by position between matched lines.
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
public struct SimilarityPairing: LinePairing {
    /// Below this share of common character bigrams two lines are not counterparts; git's rename threshold.
    public var threshold = 0.5
    /// Blocks with more removed × added lines than this pair positionally.
    public var maximumPairs = 40_000
    /// Lines longer than this, in UTF-16 units, are not compared.
    public var maximumLineLength = IntralineDiff.maximumLineLength

    public init(
        threshold: Double = 0.5,
        maximumPairs: Int = 40_000,
        maximumLineLength: Int = IntralineDiff.maximumLineLength
    ) {
        self.threshold = threshold
        self.maximumPairs = maximumPairs
        self.maximumLineLength = maximumLineLength
    }

    public func pairs(removed: [Substring], added: [Substring]) -> [LinePair] {
        pairs(removed: removed, added: added, maximumPairs: maximumPairs, maximumLineLength: maximumLineLength)
    }

    public func pairs(removed: [Substring], added: [Substring], limits: DiffLimits) -> [LinePair] {
        pairs(
            removed: removed,
            added: added,
            maximumPairs: min(maximumPairs, limits.maximumPairs),
            maximumLineLength: min(maximumLineLength, limits.maximumIntralineUnits)
        )
    }

    private func pairs(removed: [Substring], added: [Substring], maximumPairs: Int, maximumLineLength: Int)
        -> [LinePair]
    {
        guard !removed.isEmpty, !added.isEmpty, removed.count * added.count <= maximumPairs else {
            return PositionalPairing().pairs(removed: removed, added: added)
        }
        let isShort = { (line: Substring) in
            line.utf8.count <= maximumLineLength || line.utf16.count <= maximumLineLength
        }
        // A long line has no bigrams; nil keeps it apart from a short line that has none either.
        let removedGrams = removed.map { isShort($0) ? Self.bigrams($0) : nil }
        let addedGrams = added.map { isShort($0) ? Self.bigrams($0) : nil }
        // Longest-common-subsequence style dynamic programme over pair weights.
        let rows = removed.count + 1
        let columns = added.count + 1
        var weight = [Double](repeating: 0, count: rows * columns)
        for i in 1 ..< rows {
            for j in 1 ..< columns {
                let similarity = Self.similarity(removedGrams[i - 1], addedGrams[j - 1])
                var best = max(weight[(i - 1) * columns + j], weight[i * columns + j - 1])
                if similarity >= threshold {
                    best = max(best, weight[(i - 1) * columns + j - 1] + similarity)
                }
                weight[i * columns + j] = best
            }
        }
        var matches: [(old: Int, new: Int)] = []
        var i = removed.count
        var j = added.count
        while i > 0, j > 0 {
            let similarity = Self.similarity(removedGrams[i - 1], addedGrams[j - 1])
            if similarity >= threshold, weight[i * columns + j] == weight[(i - 1) * columns + j - 1] + similarity {
                matches.append((i - 1, j - 1))
                i -= 1
                j -= 1
            } else if weight[i * columns + j] == weight[(i - 1) * columns + j] {
                i -= 1
            } else {
                j -= 1
            }
        }
        // Between matched counterparts the leftovers still zip by position, so a replaced line stays one row.
        var pairs: [LinePair] = []
        var oldCursor = 0
        var newCursor = 0
        for match in matches.reversed() + [(removed.count, added.count)] {
            pairs += PositionalPairing()
                .pairs(removed: Array(removed[oldCursor ..< match.old]), added: Array(added[newCursor ..< match.new]))
                .map { LinePair(old: $0.old.map { $0 + oldCursor }, new: $0.new.map { $0 + newCursor }) }
            if match.old < removed.count { pairs.append(LinePair(old: match.old, new: match.new)) }
            oldCursor = match.old + 1
            newCursor = match.new + 1
        }
        return pairs
    }

    /// Sorted character bigrams of the line without its indentation, as UTF-16 unit pairs packed in one integer.
    static func bigrams(_ line: Substring) -> [UInt32] {
        let units = Array(line.utf16.drop(while: { $0 == 32 || $0 == 9 }))
        guard units.count > 1 else { return units.map(UInt32.init) }
        var grams: [UInt32] = []
        grams.reserveCapacity(units.count - 1)
        for index in 0 ..< (units.count - 1) {
            grams.append(UInt32(units[index]) << 16 | UInt32(units[index + 1]))
        }
        return grams.sorted()
    }

    /// ``similarity(_:_:)``, and 0 when either line was too long to compare.
    private static func similarity(_ a: [UInt32]?, _ b: [UInt32]?) -> Double {
        guard let a, let b else { return 0 }
        return similarity(a, b)
    }

    /// Sørensen–Dice coefficient of two sorted bigram multisets.
    static func similarity(_ a: [UInt32], _ b: [UInt32]) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return a.isEmpty && b.isEmpty ? 1 : 0 }
        var common = 0
        var i = 0
        var j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                common += 1
                i += 1
                j += 1
            } else if a[i] < b[j] {
                i += 1
            } else {
                j += 1
            }
        }
        return 2 * Double(common) / Double(a.count + b.count)
    }
}

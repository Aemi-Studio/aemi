/// Matches the rarest common elements first, recursing on both sides of each anchor; stretches with no rare
/// common element fall back to Myers. Mirrors JGit's `HistogramDiff`.
///
/// The lines are dense identifiers, so each level's histogram lives in three arrays kept across levels (perf-core D8):
/// how often each identifier occurs in the old range, where it first occurs, and each position's next occurrence.
/// A level fills them for its old range and clears what it touched, rather than building a dictionary of arrays.
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
struct HistogramSolver {
    private let old: [Int]
    private let new: [Int]
    private let limits: DiffLimits
    /// How the Myers searches between anchors ended: once one is cancelled, every stretch left is deleted and
    /// inserted whole.
    private(set) var outcome = SearchOutcome()
    /// Occurrences of each identifier in the range being anchored; zero outside it.
    private var counts: [Int]
    /// The first position of each identifier in that range, or -1.
    private var heads: [Int]
    /// The next position of the same identifier after each old position, or -1.
    private var nexts: [Int]

    /// - Parameters:
    ///   - old: The old side's identifiers, each in `0 ..< bound`.
    ///   - new: The new side's identifiers, each in `0 ..< bound`.
    ///   - bound: One more than the largest identifier.
    ///   - limits: The cost limit, and whether unmatched lines are set aside, for the Myers searches between anchors.
    init(old: [Int], new: [Int], bound: Int, limits: DiffLimits) {
        self.old = old
        self.new = new
        self.limits = limits
        counts = Array(repeating: 0, count: bound)
        heads = Array(repeating: -1, count: bound)
        nexts = Array(repeating: -1, count: old.count)
    }

    private struct Anchor {
        var oldStart: Int
        var newStart: Int
        var length: Int
        /// Highest occurrence count among the anchored lines; lower is rarer.
        var occurrences: Int
    }

    /// Anchors split ranges recursively; results must come out in order, so each split pushes right, anchor, left.
    private enum Work {
        case ranges(Range<Int>, Range<Int>)
        case equal(oldStart: Int, newStart: Int, count: Int)
    }

    mutating func solve(old oldRange: Range<Int>, new newRange: Range<Int>, into edits: inout [DiffEdit]) {
        var work: [Work] = [.ranges(oldRange, newRange)]
        while let item = work.popLast() {
            switch item {
                case .equal(let oldStart, let newStart, let count):
                    for index in 0 ..< count { edits.append(.equal(old: oldStart + index, new: newStart + index)) }
                case .ranges(let oldRange, let newRange):
                    if oldRange.isEmpty || newRange.isEmpty || outcome.wasCancelled {
                        for index in oldRange { edits.append(.delete(old: index)) }
                        for index in newRange { edits.append(.insert(new: index)) }
                    } else if let anchor = bestAnchor(old: oldRange, new: newRange) {
                        work.append(
                            .ranges(
                                (anchor.oldStart + anchor.length) ..< oldRange.upperBound,
                                (anchor.newStart + anchor.length) ..< newRange.upperBound
                            )
                        )
                        work.append(.equal(oldStart: anchor.oldStart, newStart: anchor.newStart, count: anchor.length))
                        work.append(
                            .ranges(oldRange.lowerBound ..< anchor.oldStart, newRange.lowerBound ..< anchor.newStart)
                        )
                    } else {
                        outcome.merge(
                            LineDiff.solveMatched(old, oldRange, new, newRange, limits: limits, into: &edits)
                        )
                    }
            }
        }
    }

    /// The longest run of common lines whose rarest line is as rare as possible, or nil when every common line is
    /// too frequent to anchor on.
    /// - Complexity: O(old range + new range × candidates), in no allocation.
    private mutating func bestAnchor(old oldRange: Range<Int>, new newRange: Range<Int>) -> Anchor? {
        // Positions are pushed from the last, so each identifier's chain runs in ascending order.
        for index in oldRange.reversed() {
            let identifier = old[index]
            nexts[index] = heads[identifier]
            heads[identifier] = index
            counts[identifier] += 1
        }
        defer {
            for index in oldRange {
                counts[old[index]] = 0
                heads[old[index]] = -1
            }
        }
        var best: Anchor?
        var newIndex = newRange.lowerBound
        while newIndex < newRange.upperBound {
            let candidates = counts[new[newIndex]]
            guard candidates > 0, candidates <= LineDiff.maximumAnchorOccurrences else {
                newIndex += 1
                continue
            }
            var nextNewIndex = newIndex + 1
            var oldIndex = heads[new[newIndex]]
            while oldIndex >= 0 {
                if let current = best, candidates > current.occurrences { break }
                let anchor = extend(
                    oldIndex: oldIndex,
                    newIndex: newIndex,
                    candidates: candidates,
                    old: oldRange,
                    new: newRange
                )
                if let current = best {
                    if anchor.occurrences < current.occurrences
                        || (anchor.occurrences == current.occurrences && anchor.length > current.length)
                    {
                        best = anchor
                    }
                } else {
                    best = anchor
                }
                nextNewIndex = max(nextNewIndex, anchor.newStart + anchor.length)
                oldIndex = nexts[oldIndex]
            }
            newIndex = nextNewIndex
        }
        return best
    }

    /// The run of common lines through `oldIndex` and `newIndex`, as far as it goes both ways within the ranges, with
    /// the highest occurrence count among its lines.
    private func extend(
        oldIndex: Int,
        newIndex: Int,
        candidates: Int,
        old oldRange: Range<Int>,
        new newRange: Range<Int>
    )
        -> Anchor
    {
        var oldStart = oldIndex
        var newStart = newIndex
        var occurrences = candidates
        while oldStart > oldRange.lowerBound, newStart > newRange.lowerBound, old[oldStart - 1] == new[newStart - 1] {
            oldStart -= 1
            newStart -= 1
            occurrences = max(occurrences, counts[old[oldStart]])
        }
        var oldEnd = oldIndex + 1
        var newEnd = newIndex + 1
        while oldEnd < oldRange.upperBound, newEnd < newRange.upperBound, old[oldEnd] == new[newEnd] {
            occurrences = max(occurrences, counts[old[oldEnd]])
            oldEnd += 1
            newEnd += 1
        }
        return Anchor(oldStart: oldStart, newStart: newStart, length: oldEnd - oldStart, occurrences: occurrences)
    }
}

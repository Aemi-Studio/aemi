/// One entry of an edit script, in output order.
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
public enum DiffEdit: Equatable, Sendable {
    case equal(old: Int, new: Int)
    case delete(old: Int)
    case insert(new: Int)
}

/// Produces an edit script between two interned line sequences.
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
public protocol LineDiffing: Sendable {
    func diff(_ old: [Int], _ new: [Int]) -> [DiffEdit]
    /// The edit script within `limits`, and whether the search found the script it looks for rather than settling at
    /// the cost limit or stopping for a cancellation.
    func diff(_ old: [Int], _ new: [Int], limits: DiffLimits) -> LineDiffResult
}

@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
extension LineDiffing {
    /// A differ that knows no limits: its script, taken as the one it looks for.
    public func diff(_ old: [Int], _ new: [Int], limits: DiffLimits) -> LineDiffResult {
        LineDiffResult(edits: diff(old, new), isMinimal: true)
    }
}

/// An edit script, and whether it is the one its search looks for: false when a search settled for a heuristic split
/// at the cost limit, or stopped for a cancellation, which leaves a valid script that may not be the shortest.
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
public struct LineDiffResult: Sendable, Equatable {
    public var edits: [DiffEdit]
    public var isMinimal: Bool

    public init(edits: [DiffEdit], isMinimal: Bool) {
        self.edits = edits
        self.isMinimal = isMinimal
    }
}

/// Adjusts an edit script without changing what it reconstructs, using the line text for its judgement.
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
public protocol EditScriptRefining: Sendable {
    func refine(_ edits: [DiffEdit], lines: LineDiffContext) -> [DiffEdit]
}

/// What refiners may look at: the interned ids and the leading indentation of every line on both sides.
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
public struct LineDiffContext: Sendable {
    public let old: [Int]
    public let new: [Int]
    /// Leading whitespace width per line, tabs to the next multiple of eight; nil for a blank line.
    public let oldIndents: [Int?]
    public let newIndents: [Int?]

    public init(old: [Int], new: [Int], oldIndents: [Int?], newIndents: [Int?]) {
        self.old = old
        self.new = new
        self.oldIndents = oldIndents
        self.newIndents = newIndents
    }
}

/// Shortest edit script: linear-space Myers ("An O(ND) Difference Algorithm and Its Variations", section 4b) over the
/// lines both sides share, with git's cost limit, past which the script stays valid but may not be the shortest.
/// - Complexity: O((N + M) * D) time and O(N + M) space, where D is the size of the edit script; a search stops
///   after about 4√(N + M) rounds.
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
public struct MyersLineDiff: LineDiffing {
    public init() {}

    public func diff(_ old: [Int], _ new: [Int]) -> [DiffEdit] {
        LineDiff.diff(old, new, anchoringRareLines: false)
    }

    public func diff(_ old: [Int], _ new: [Int], limits: DiffLimits) -> LineDiffResult {
        LineDiff.diff(old, new, anchoringRareLines: false, limits: limits)
    }
}

/// Git's `histogram` algorithm: the rarest lines common to both sides are matched first and anchor the alignment,
/// Myers fills the stretches between anchors. Anchoring keeps repetitive lines (braces, blank lines) from being
/// matched across unrelated regions, which is where a plain shortest edit script reads wrong.
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
public struct HistogramLineDiff: LineDiffing {
    public init() {}

    public func diff(_ old: [Int], _ new: [Int]) -> [DiffEdit] {
        LineDiff.diff(old, new, anchoringRareLines: true)
    }

    public func diff(_ old: [Int], _ new: [Int], limits: DiffLimits) -> LineDiffResult {
        LineDiff.diff(old, new, anchoringRareLines: true, limits: limits)
    }
}

@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
public enum LineDiff {
    /// Lines occurring more often than this on the old side are never anchors; JGit's limit.
    static let maximumAnchorOccurrences = 64

    /// Shared prefix and suffix are matched directly; the middle goes to the histogram anchoring or to Myers.
    ///
    /// Myers sets aside the lines that occur on one side only, which can never match, and stops looking for the
    /// shortest script once its search passes ``costLimit(lines:)``, splitting the problem heuristically instead, as
    /// git does. A task cancelled while it runs gets a valid script that is not the shortest: the search stops within
    /// 64 rounds and whatever is left is deleted and inserted whole.
    public static func diff<Element: Hashable>(_ old: [Element], _ new: [Element], anchoringRareLines: Bool = true)
        -> [DiffEdit]
    {
        diff(old, new, anchoringRareLines: anchoringRareLines, costLimit: nil)
    }

    /// ``diff(_:_:anchoringRareLines:)`` with `costLimit`, when given, in place of every search's own limit.
    static func diff<Element: Hashable>(
        _ old: [Element],
        _ new: [Element],
        anchoringRareLines: Bool,
        costLimit: Int?
    ) -> [DiffEdit] {
        diff(old, new, anchoringRareLines: anchoringRareLines, limits: DiffLimits(costLimit: costLimit)).edits
    }

    /// ``diff(_:_:anchoringRareLines:)`` within `limits`: their cost limit in place of every search's own, and the
    /// lines on one side only set aside before Myers when they say so.
    static func diff<Element: Hashable>(
        _ old: [Element],
        _ new: [Element],
        anchoringRareLines: Bool,
        limits: DiffLimits
    ) -> LineDiffResult {
        var edits: [DiffEdit] = []
        edits.reserveCapacity(max(old.count, new.count))
        let middle = matchEnds(old, new, into: &edits)
        var search = SearchOutcome()
        if anchoringRareLines {
            let (oldIdentifiers, newIdentifiers, bound) = denseIdentifiers(old, new)
            var histogram = HistogramSolver(old: oldIdentifiers, new: newIdentifiers, bound: bound, limits: limits)
            histogram.solve(old: middle.old, new: middle.new, into: &edits)
            search = histogram.outcome
        } else {
            search = solveMatched(old, middle.old, new, middle.new, limits: limits, into: &edits)
        }
        for offset in 0 ..< (old.count - middle.old.upperBound) {
            edits.append(.equal(old: middle.old.upperBound + offset, new: middle.new.upperBound + offset))
        }
        return LineDiffResult(edits: edits, isMinimal: !search.wasCancelled && !search.reachedCostLimit)
    }

    /// `old` and `new` as identifiers in `0 ..< bound`, equal where the elements are: the identifiers themselves
    /// when they already are small non-negative integers, as interned lines are, else numbered in first-seen order.
    /// - Complexity: O(`old.count` + `new.count`)
    static func denseIdentifiers<Element: Hashable>(_ old: [Element], _ new: [Element]) -> ([Int], [Int], Int) {
        let cap = 4 * (old.count + new.count) + 1_024
        if let oldIdentifiers = old as? [Int], let newIdentifiers = new as? [Int] {
            let low = min(oldIdentifiers.min() ?? 0, newIdentifiers.min() ?? 0)
            let high = max(oldIdentifiers.max() ?? 0, newIdentifiers.max() ?? 0)
            if low >= 0, high < cap { return (oldIdentifiers, newIdentifiers, high + 1) }
        }
        var numbers: [Element: Int] = [:]
        numbers.reserveCapacity(old.count)
        let number = { (element: Element) -> Int in
            if let known = numbers[element] { return known }
            numbers[element] = numbers.count
            return numbers.count - 1
        }
        let oldIdentifiers = old.map(number)
        let newIdentifiers = new.map(number)
        return (oldIdentifiers, newIdentifiers, numbers.count)
    }

    /// The shortest edit script when it holds at most `maximumEdits` edits, else nil, as it is when the task is
    /// cancelled. The search gives up in the round that proves the script longer, so a pair too different to be worth
    /// it costs a fraction of a full diff.
    static func diff<Element: Hashable>(_ old: [Element], _ new: [Element], maximumEdits: Int) -> [DiffEdit]? {
        var edits: [DiffEdit] = []
        let middle = matchEnds(old, new, into: &edits)
        // With a side empty, the script deletes or inserts the other one whole, and no search runs.
        if middle.old.isEmpty || middle.new.isEmpty, middle.old.count + middle.new.count > maximumEdits { return nil }
        // No cost limit: every snake is then exact, so the first one tells the cost of the whole script.
        var solver = MyersSolver(old: old, new: new, costLimit: .max, maximumEdits: maximumEdits)
        solver.solve(old: middle.old, new: middle.new, into: &edits)
        guard !solver.exceededBudget, !solver.wasCancelled else { return nil }
        for offset in 0 ..< (old.count - middle.old.upperBound) {
            edits.append(.equal(old: middle.old.upperBound + offset, new: middle.new.upperBound + offset))
        }
        return edits
    }

    /// Rounds a middle-snake search over `lines` lines on both sides may take before it settles for a heuristic
    /// split: four times the square root of the problem size, and never fewer than 256. git's `mxcost` takes the
    /// square root alone; the factor of four is the limit perf-core measured.
    static func costLimit(lines: Int) -> Int {
        max(256, 4 * Int(Double(lines).squareRoot()))
    }

    /// Where Myers splits a problem of `n` old and `m` new lines once its search reaches the cost limit in round `d`:
    /// at the point furthest along round `d - 1`'s forward paths, by x + y, whose diagonal stays in the problem, where
    /// `reach(k)` is the x that round reached on diagonal `k`; or, when that point is a corner, at an inner point,
    /// since a split at (0, 0) or (n, m) would hand the same problem back. git's `xdl_split` heuristic as perf-core
    /// corrected it, with a fallback that stays inner for a 1 by 1 problem too.
    static func costLimitedSplit(round d: Int, n: Int, m: Int, reach: (Int) -> Int) -> (x: Int, y: Int) {
        var bestK = 1 - d
        var bestReach = -1
        for k in stride(from: 1 - d, through: d - 1, by: 2) {
            let x = min(reach(k), n)
            let y = x - k
            if y >= 0, y <= m, x + y > bestReach {
                bestReach = x + y
                bestK = k
            }
        }
        let x = min(reach(bestK), n)
        let y = max(0, min(m, x - bestK))
        guard x + y == 0 || (x == n && y == m) else { return (x, y) }
        return ((n + 1) / 2, m / 2)
    }

    /// Appends the shared prefix as equal lines and returns the ranges left between it and the shared suffix.
    private static func matchEnds<Element: Equatable>(_ old: [Element], _ new: [Element], into edits: inout [DiffEdit])
        -> (old: Range<Int>, new: Range<Int>)
    {
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] {
            edits.append(.equal(old: prefix, new: prefix))
            prefix += 1
        }
        var oldEnd = old.count
        var newEnd = new.count
        while oldEnd > prefix, newEnd > prefix, old[oldEnd - 1] == new[newEnd - 1] {
            oldEnd -= 1
            newEnd -= 1
        }
        return (prefix ..< oldEnd, prefix ..< newEnd)
    }

    /// Myers over the lines of the two ranges that occur on both sides, the others put back as deletions and
    /// insertions where they fall. A line found on one side only can never be matched, so setting it aside leaves the
    /// shortest script as short as it was while the search runs on a smaller problem; git's `xdl_cleanup_records`.
    /// With `limits.discardsUnmatchedLines` off, Myers runs over the ranges whole.
    /// - Returns: Whether a cancellation stopped the search, or the cost limit cut it short.
    static func solveMatched<Element: Hashable>(
        _ old: [Element],
        _ oldRange: Range<Int>,
        _ new: [Element],
        _ newRange: Range<Int>,
        limits: DiffLimits,
        into edits: inout [DiffEdit]
    ) -> SearchOutcome {
        guard limits.discardsUnmatchedLines else {
            var solver = MyersSolver(
                old: old,
                new: new,
                costLimit: limits.costLimit ?? Self.costLimit(lines: oldRange.count + newRange.count)
            )
            solver.solve(old: oldRange, new: newRange, into: &edits)
            return SearchOutcome(wasCancelled: solver.wasCancelled, reachedCostLimit: solver.reachedCostLimit)
        }
        let (keptOld, keptNew) = matchedPositions(old, oldRange, new, newRange)
        var solver = MyersSolver(
            old: keptOld.map { old[$0] },
            new: keptNew.map { new[$0] },
            costLimit: limits.costLimit ?? Self.costLimit(lines: keptOld.count + keptNew.count)
        )
        var kept: [DiffEdit] = []
        kept.reserveCapacity(keptOld.count + keptNew.count)
        solver.solve(old: 0 ..< keptOld.count, new: 0 ..< keptNew.count, into: &kept)

        // Each set-aside line goes in just before the first kept line that follows it on its side.
        var oldIndex = oldRange.lowerBound
        var newIndex = newRange.lowerBound
        for edit in kept {
            switch edit {
                case .equal(let oldKept, let newKept):
                    while oldIndex < keptOld[oldKept] {
                        edits.append(.delete(old: oldIndex))
                        oldIndex += 1
                    }
                    while newIndex < keptNew[newKept] {
                        edits.append(.insert(new: newIndex))
                        newIndex += 1
                    }
                    edits.append(.equal(old: oldIndex, new: newIndex))
                    oldIndex += 1
                    newIndex += 1
                case .delete(let oldKept):
                    while oldIndex <= keptOld[oldKept] {
                        edits.append(.delete(old: oldIndex))
                        oldIndex += 1
                    }
                case .insert(let newKept):
                    while newIndex <= keptNew[newKept] {
                        edits.append(.insert(new: newIndex))
                        newIndex += 1
                    }
            }
        }
        for index in oldIndex ..< oldRange.upperBound { edits.append(.delete(old: index)) }
        for index in newIndex ..< newRange.upperBound { edits.append(.insert(new: index)) }
        return SearchOutcome(wasCancelled: solver.wasCancelled, reachedCostLimit: solver.reachedCostLimit)
    }

    /// The positions in `oldRange` whose line also occurs in `newRange`, and the other way round.
    private static func matchedPositions<Element: Hashable>(
        _ old: [Element],
        _ oldRange: Range<Int>,
        _ new: [Element],
        _ newRange: Range<Int>
    ) -> (old: [Int], new: [Int]) {
        // Interned lines are small integers: marking them in two arrays costs a fraction of hashing them into sets,
        // which would be most of this pass on a large diff. Where `Element` is `Int` the casts compile away.
        if let oldIdentifiers = old as? [Int], let newIdentifiers = new as? [Int],
            let matched = denseMatchedPositions(oldIdentifiers, oldRange, newIdentifiers, newRange)
        {
            return matched
        }
        let onOld = Set(old[oldRange])
        let onNew = Set(new[newRange])
        return (oldRange.filter { onNew.contains(old[$0]) }, newRange.filter { onOld.contains(new[$0]) })
    }

    /// ``matchedPositions(_:_:_:_:)`` over identifiers marked in arrays, or nil when one is negative or too large for
    /// an array about the size of the ranges, as a stretch of a larger diff can hold.
    private static func denseMatchedPositions(
        _ old: [Int],
        _ oldRange: Range<Int>,
        _ new: [Int],
        _ newRange: Range<Int>
    ) -> (old: [Int], new: [Int])? {
        let bound = 2 * (oldRange.count + newRange.count) + 1_024
        guard old[oldRange].allSatisfy({ (0 ..< bound).contains($0) }),
            new[newRange].allSatisfy({ (0 ..< bound).contains($0) })
        else { return nil }
        var onOld = [Bool](repeating: false, count: bound)
        var onNew = onOld
        for index in oldRange { onOld[old[index]] = true }
        for index in newRange { onNew[new[index]] = true }
        return (oldRange.filter { onNew[old[$0]] }, newRange.filter { onOld[new[$0]] })
    }

    /// Diffs lines through `pipeline`: interned so each comparison in the inner loop is an integer comparison,
    /// then refined by every stage the pipeline wires in.
    public static func diffLines(_ old: [Substring], _ new: [Substring], pipeline: DiffPipeline = DiffPipeline())
        -> [DiffEdit]
    {
        diffLines(old: SubstringLines(old), new: SubstringLines(new), pipeline: pipeline)
    }

    /// The edit script between two line sources: lines are interned under the pipeline's whitespace mode, the
    /// line diff runs over the identifiers, and the refiners see the indents measured on the bytes.
    /// - Complexity: O(bytes) to intern, plus the line diff's own cost.
    public static func diffLines(old: some DiffSource, new: some DiffSource, pipeline: DiffPipeline = DiffPipeline())
        -> [DiffEdit]
    {
        makeStructure(old: old, new: new, pipeline: pipeline, limits: DiffLimits()).edits
    }

    /// Leading whitespace width with tabs to the next multiple of eight, or nil for a blank line; git's `get_indent`.
    static func indent(of line: Substring) -> Int? {
        line.utf8.withContiguousStorageIfAvailable { unsafe indent(of: Span(_unsafeElements: $0)) }
            ?? indent(of: Array(line.utf8).span)
    }

    static func indent(of line: Span<UInt8>) -> Int? {
        var width = 0
        for index in 0 ..< line.count {
            let byte = line[index]
            switch byte {
                case UInt8(ascii: " "): width += 1
                case UInt8(ascii: "\t"): width += 8 - width % 8
                case UInt8(ascii: "\r"), UInt8(ascii: "\u{0C}"), UInt8(ascii: "\u{0B}"): continue
                default: return min(width, IndentHeuristic.maximumIndent)
            }
        }
        return nil
    }
}

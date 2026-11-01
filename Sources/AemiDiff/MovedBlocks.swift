/// Which lines of each side only moved: one flag per line (perf-core D6), set on a removed line whose block was added
/// unchanged elsewhere, and on the added line it went to.
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
public struct MovedLines: Sendable, Equatable {
    public var old: [Bool]
    public var new: [Bool]

    public init(old: [Bool], new: [Bool]) {
        self.old = old
        self.new = new
    }

    /// Whether any line moved.
    public var isEmpty: Bool { !old.contains(true) }
}

/// Blocks of lines that were removed in one place and added unchanged in another; git's `--color-moved` idea.
/// Only runs of at least `minimumLines` count, since single moved lines are mostly coincidence.
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
public enum MovedBlocks {
    public static let minimumLines = 3

    /// A diff's third phase (review §7.4, P1b): the moved lines of `structure`, compared by the identifiers the line
    /// diff interned, so no line is hashed again (Core S14) and lines are equal exactly when the diff says so.
    /// - Complexity: O(changed lines × `limits.maximumMovedCandidates` × block length) at worst.
    public static func detect(in structure: DiffStructure, limits: DiffLimits = DiffLimits()) -> MovedLines {
        var removed: [(index: Int, id: Int)] = []
        var added: [(index: Int, id: Int)] = []
        for edit in structure.edits {
            switch edit {
                case .delete(let index): removed.append((index, structure.lines.old[index]))
                case .insert(let index): added.append((index, structure.lines.new[index]))
                case .equal: break
            }
        }
        var moved = MovedLines(
            old: Array(repeating: false, count: structure.lines.old.count),
            new: Array(repeating: false, count: structure.lines.new.count))
        mark(removed: removed, added: added, maximumCandidates: limits.maximumMovedCandidates) { old, new in
            moved.old[old] = true
            moved.new[new] = true
        }
        return moved
    }

    /// Old and new line indices that belong to a moved block, given the removed and added line ids of a diff. A line
    /// with more than `maximumCandidates` removed occurrences starts no block.
    /// - Complexity: O(added lines × `maximumCandidates` × block length) at worst.
    public static func detect(
        removed: [(index: Int, id: Int)], added: [(index: Int, id: Int)],
        maximumCandidates: Int = DiffLimits().maximumMovedCandidates
    ) -> (old: Set<Int>, new: Set<Int>) {
        var movedOld: Set<Int> = []
        var movedNew: Set<Int> = []
        mark(removed: removed, added: added, maximumCandidates: maximumCandidates) { old, new in
            movedOld.insert(old)
            movedNew.insert(new)
        }
        return (movedOld, movedNew)
    }

    /// Calls `moved` with each removed line and the added line it moved to.
    private static func mark(
        removed: [(index: Int, id: Int)], added: [(index: Int, id: Int)], maximumCandidates: Int,
        moved: (_ old: Int, _ new: Int) -> Void
    ) {
        let removedRuns = runs(of: removed)
        let addedRuns = runs(of: added)
        guard !removedRuns.isEmpty, !addedRuns.isEmpty else { return }
        var positions: [Int: [(run: Int, offset: Int)]] = [:]
        for (runIndex, run) in removedRuns.enumerated() {
            for (offset, line) in run.enumerated() { positions[line.id, default: []].append((runIndex, offset)) }
        }
        for run in addedRuns {
            var start = 0
            while start < run.count {
                var bestLength = 0
                var bestMatch: (run: Int, offset: Int)?
                let candidates = positions[run[start].id] ?? []
                for candidate in candidates where candidates.count <= maximumCandidates {
                    let source = removedRuns[candidate.run]
                    var length = 0
                    while start + length < run.count, candidate.offset + length < source.count,
                        run[start + length].id == source[candidate.offset + length].id
                    {
                        length += 1
                    }
                    if length > bestLength {
                        bestLength = length
                        bestMatch = candidate
                    }
                }
                if let bestMatch, bestLength >= minimumLines {
                    let source = removedRuns[bestMatch.run]
                    for offset in 0 ..< bestLength {
                        moved(source[bestMatch.offset + offset].index, run[start + offset].index)
                    }
                    start += bestLength
                } else {
                    start += 1
                }
            }
        }
    }

    /// Consecutive lines grouped into runs.
    private static func runs(of lines: [(index: Int, id: Int)]) -> [[(index: Int, id: Int)]] {
        var runs: [[(index: Int, id: Int)]] = []
        for line in lines {
            if let last = runs.last?.last, last.index + 1 == line.index {
                runs[runs.count - 1].append(line)
            } else {
                runs.append([line])
            }
        }
        return runs
    }
}

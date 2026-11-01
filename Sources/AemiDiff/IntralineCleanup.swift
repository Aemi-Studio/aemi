/// Adjusts the token-level edit script of a line pair without changing what it reconstructs.
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
public protocol IntralineRefining: Sendable {
    /// - Parameters:
    ///   - edits: The token-level edit script to adjust.
    ///   - oldRanges: Unit ranges of the old line's tokens, the edit script's deletions index into them.
    ///   - newRanges: Unit ranges of the new line's tokens, the edit script's insertions index into them.
    /// - Returns: An edit script over the same tokens that reconstructs the same lines.
    func refine(_ edits: [DiffEdit], oldRanges: [Range<Int>], newRanges: [Range<Int>]) -> [DiffEdit]
}

/// diff-match-patch's semantic cleanup: an equality short enough to be coincidence between two changes is folded
/// into them, so `foo` to `bar` reads as one replacement rather than as scattered common letters.
///
/// The runs of the script are ranges of it, and a folded equality is a flag per edit, so a pass allocates nothing per
/// edit (perf-core D5); the script is rebuilt once at the end.
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
public struct SemanticCleanup: IntralineRefining {
    public init() {}

    public func refine(_ edits: [DiffEdit], oldRanges: [Range<Int>], newRanges: [Range<Int>]) -> [DiffEdit] {
        var runs = Run.runs(of: edits, oldRanges: oldRanges, newRanges: newRanges)
        var folded = [Bool](repeating: false, count: edits.count)
        var changed = true
        while changed {
            changed = false
            var index = 1
            while index < runs.count - 1 {
                let run = runs[index]
                // An equality no longer than the longer side of the change on either side of it is folded in.
                if run.isEqual, run.units <= runs[index - 1].units, run.units <= runs[index + 1].units {
                    for edit in run.edits { folded[edit] = true }
                    runs[index].isEqual = false
                    changed = true
                }
                index += 1
            }
            if changed { runs = Run.merged(runs) }
        }
        var result: [DiffEdit] = []
        result.reserveCapacity(edits.count)
        for (index, edit) in edits.enumerated() {
            if folded[index], case .equal(let old, let new) = edit {
                result.append(.delete(old: old))
                result.append(.insert(new: new))
            } else {
                result.append(edit)
            }
        }
        return result.sorted(by: Self.scriptOrder)
    }

    /// Deletions before insertions within one change, both in index order; equalities keep their place.
    private static func scriptOrder(_ lhs: DiffEdit, _ rhs: DiffEdit) -> Bool {
        position(of: lhs) < position(of: rhs)
    }

    private static func position(of edit: DiffEdit) -> (Int, Int, Int) {
        switch edit {
            case .equal(let old, let new): (old + new, 0, 0)
            case .delete(let old): (old * 2, 1, old)
            case .insert(let new): (new * 2, 2, new)
        }
    }

    /// A run of equalities, or of deletions and insertions, as a range of the script.
    private struct Run {
        var edits: Range<Int>
        /// Units on the old side and on the new side; equal for an equality.
        var deleted: Int
        var inserted: Int
        var isEqual: Bool

        /// The units of the run's longer side.
        var units: Int { max(deleted, inserted) }

        static func runs(of edits: [DiffEdit], oldRanges: [Range<Int>], newRanges: [Range<Int>]) -> [Run] {
            var runs: [Run] = []
            for (index, edit) in edits.enumerated() {
                let run: Run
                switch edit {
                    case .equal(let old, _):
                        let units = oldRanges[old].count
                        run = Run(edits: index ..< index + 1, deleted: units, inserted: units, isEqual: true)
                    case .delete(let old):
                        run = Run(
                            edits: index ..< index + 1,
                            deleted: oldRanges[old].count,
                            inserted: 0,
                            isEqual: false
                        )
                    case .insert(let new):
                        run = Run(
                            edits: index ..< index + 1,
                            deleted: 0,
                            inserted: newRanges[new].count,
                            isEqual: false
                        )
                }
                append(run, to: &runs)
            }
            return runs
        }

        static func merged(_ runs: [Run]) -> [Run] {
            var merged: [Run] = []
            merged.reserveCapacity(runs.count)
            for run in runs { append(run, to: &merged) }
            return merged
        }

        /// Adds `run` to `runs`, joined to the last one when both are equalities or both are changes: the runs of a
        /// script are contiguous, so joining extends the range.
        private static func append(_ run: Run, to runs: inout [Run]) {
            guard let last = runs.last, last.isEqual == run.isEqual else {
                runs.append(run)
                return
            }
            runs[runs.count - 1] = Run(
                edits: last.edits.lowerBound ..< run.edits.upperBound,
                deleted: last.deleted + run.deleted,
                inserted: last.inserted + run.inserted,
                isEqual: last.isEqual
            )
        }
    }
}

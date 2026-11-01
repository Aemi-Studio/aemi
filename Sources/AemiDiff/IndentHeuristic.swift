/// Git's indent heuristic (`xdiff/xdiffi.c`): a run of inserted or deleted lines can often slide up or down over
/// identical lines without changing the diff; among those positions, prefer the one that starts on a shallow
/// indentation and after blank lines, the way a reader would cut the change.
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
public struct IndentHeuristic: EditScriptRefining {
    static let maximumIndent = 200
    static let maximumBlanks = 20
    static let maximumSliding = 100
    private static let startOfFilePenalty = 1
    private static let endOfFilePenalty = 21
    private static let totalBlankWeight = -30
    private static let postBlankWeight = 18
    private static let relativeIndentPenalty = -4
    private static let relativeIndentWithBlankPenalty = 10
    private static let relativeOutdentPenalty = 24
    private static let relativeOutdentWithBlankPenalty = 17
    private static let relativeDedentPenalty = 23
    private static let relativeDedentWithBlankPenalty = 17
    private static let indentWeight = 60

    public init() {}

    public func refine(_ edits: [DiffEdit], lines: LineDiffContext) -> [DiffEdit] {
        Self.slide(edits, old: lines.old, new: lines.new, oldIndents: lines.oldIndents, newIndents: lines.newIndents)
    }

    static func slide(_ edits: [DiffEdit], old: [Int], new: [Int], oldIndents: [Int?], newIndents: [Int?]) -> [DiffEdit]
    {
        var oldChanged = [Bool](repeating: false, count: old.count)
        var newChanged = [Bool](repeating: false, count: new.count)
        for edit in edits {
            switch edit {
                case .delete(let index): oldChanged[index] = true
                case .insert(let index): newChanged[index] = true
                case .equal: break
            }
        }
        slideGroups(lines: old, indents: oldIndents, changed: &oldChanged)
        slideGroups(lines: new, indents: newIndents, changed: &newChanged)

        var result: [DiffEdit] = []
        result.reserveCapacity(edits.count)
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < old.count || newIndex < new.count {
            if oldIndex < old.count, newIndex < new.count, !oldChanged[oldIndex], !newChanged[newIndex] {
                result.append(.equal(old: oldIndex, new: newIndex))
                oldIndex += 1
                newIndex += 1
                continue
            }
            while oldIndex < old.count, oldChanged[oldIndex] {
                result.append(.delete(old: oldIndex))
                oldIndex += 1
            }
            while newIndex < new.count, newChanged[newIndex] {
                result.append(.insert(new: newIndex))
                newIndex += 1
            }
        }
        return result
    }

    private static func slideGroups(lines: [Int], indents: [Int?], changed: inout [Bool]) {
        var end = 0
        while end < lines.count {
            guard changed[end] else {
                end += 1
                continue
            }
            var start = end
            while end < lines.count, changed[end] { end += 1 }
            // Slide up as far as identical lines allow, then down; the reachable positions are the candidates.
            while start > 0, !changed[start - 1], lines[start - 1] == lines[end - 1] {
                start -= 1
                end -= 1
                changed[start] = true
                changed[end] = false
            }
            let earliestEnd = end
            while end < lines.count, !changed[end], lines[end] == lines[start] {
                changed[start] = false
                changed[end] = true
                start += 1
                end += 1
            }
            let groupSize = end - start
            if end - earliestEnd > maximumSliding {
                // Too many positions to score; the group stays slid down, which is what git does too.
            } else if end > earliestEnd {
                var bestEnd = end
                var bestScore: Score?
                var candidate = earliestEnd
                while candidate <= end {
                    let score =
                        measure(lines: lines, indents: indents, split: candidate)
                        + measure(lines: lines, indents: indents, split: candidate - groupSize)
                    if let current = bestScore, score.compared(to: current) > 0 {
                        // worse than best
                    } else {
                        bestScore = score
                        bestEnd = candidate
                    }
                    candidate += 1
                }
                while end > bestEnd {
                    end -= 1
                    start -= 1
                    changed[start] = true
                    changed[end] = false
                }
            }
            // A group that slid down to touch the next one is now one group; continue after it.
        }
    }

    private struct Score {
        var effectiveIndent = 0
        var penalty = 0

        static func + (lhs: Score, rhs: Score) -> Score {
            Score(effectiveIndent: lhs.effectiveIndent + rhs.effectiveIndent, penalty: lhs.penalty + rhs.penalty)
        }

        /// Negative when `self` is the better split.
        func compared(to other: Score) -> Int {
            let indentOrder =
                (effectiveIndent > other.effectiveIndent ? 1 : 0) - (effectiveIndent < other.effectiveIndent ? 1 : 0)
            return indentWeight * indentOrder + (penalty - other.penalty)
        }
    }

    /// Scores a split between line `split - 1` and line `split`; git's `measure_split` and `score_add_split`.
    private static func measure(lines: [Int], indents: [Int?], split: Int) -> Score {
        let endOfFile = split >= lines.count
        let indent: Int? = endOfFile ? nil : indents[split]
        var preBlank = 0
        var preIndent: Int?
        var index = split - 1
        while index >= 0 {
            if let value = indents[index] {
                preIndent = value
                break
            }
            preBlank += 1
            if preBlank == maximumBlanks { break }
            index -= 1
        }
        var postBlank = 0
        var postIndent: Int?
        index = split + 1
        while index < lines.count {
            if let value = indents[index] {
                postIndent = value
                break
            }
            postBlank += 1
            if postBlank == maximumBlanks { break }
            index += 1
        }

        var penalty = 0
        if preIndent == nil, preBlank == 0 { penalty += startOfFilePenalty }
        if endOfFile { penalty += endOfFilePenalty }
        let totalBlank = preBlank + postBlank
        penalty += totalBlankWeight * totalBlank
        penalty += postBlankWeight * postBlank
        let effectiveIndent: Int
        if let indent {
            effectiveIndent = indent
        } else {
            effectiveIndent = postIndent ?? -1
        }
        let anyBlanks = totalBlank > 0
        if let indent, let preIndent {
            if indent > preIndent {
                penalty += anyBlanks ? relativeIndentWithBlankPenalty : relativeIndentPenalty
            } else if indent < preIndent {
                if let postIndent, postIndent > indent {
                    penalty += anyBlanks ? relativeOutdentWithBlankPenalty : relativeOutdentPenalty
                } else {
                    penalty += anyBlanks ? relativeDedentWithBlankPenalty : relativeDedentPenalty
                }
            }
        }
        return Score(effectiveIndent: effectiveIndent, penalty: penalty)
    }
}

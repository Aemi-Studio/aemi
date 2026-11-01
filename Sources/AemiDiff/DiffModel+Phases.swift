@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
extension DiffModel {
    /// This model with the emphasis of the changes `emphasis` holds, by change index; the other changes keep theirs.
    /// A row keeps whether it moved.
    /// - Complexity: O(pairs of those changes)
    public func applying(_ emphasis: [Int: ChangeEmphasis]) -> DiffModel {
        var model = self
        for (index, change) in emphasis where index < structure.changes.count && index < changePairs.count {
            let lines = structure.changes[index]
            let unifiedStart = unifiedChangeRanges[index].lowerBound
            let splitStart = splitChangeRanges[index].lowerBound
            for (offset, pair) in changePairs[index].enumerated() where offset < change.lines.count {
                guard let line = change.lines[offset], let old = pair.old, let new = pair.new else { continue }
                let oldRef = DiffLineRef(index: lines.old.lowerBound + old, emphasis: line.old)
                let newRef = DiffLineRef(index: lines.new.lowerBound + new, emphasis: line.new)
                let removed = unifiedStart + old
                let added = unifiedStart + lines.old.count + new
                let split = splitStart + offset
                model.unifiedRows[removed] = DiffRow(
                    kind: .removed,
                    old: oldRef,
                    new: nil,
                    isMoved: model.unifiedRows[removed].isMoved
                )
                model.unifiedRows[added] = DiffRow(
                    kind: .added,
                    old: nil,
                    new: newRef,
                    isMoved: model.unifiedRows[added].isMoved
                )
                model.splitRows[split] = DiffRow(
                    kind: .modified,
                    old: oldRef,
                    new: newRef,
                    isMoved: model.splitRows[split].isMoved
                )
            }
        }
        return model
    }

    /// This model with the rows of the lines `moved` flags marked as moved. A split row that pairs a moved line with
    /// one that did not move stays unmarked, since the pair reads as a change.
    /// - Complexity: O(rows)
    public func applying(_ moved: MovedLines) -> DiffModel {
        guard !moved.isEmpty else { return self }
        func isMoved(_ flags: [Bool], _ ref: DiffLineRef?) -> Bool {
            guard let ref, ref.index < flags.count else { return false }
            return flags[ref.index]
        }
        var model = self
        for index in model.unifiedRows.indices {
            let row = model.unifiedRows[index]
            if row.kind == .removed, isMoved(moved.old, row.old) { model.unifiedRows[index].isMoved = true }
            if row.kind == .added, isMoved(moved.new, row.new) { model.unifiedRows[index].isMoved = true }
        }
        for index in model.splitRows.indices {
            let row = model.splitRows[index]
            let oldMoved = isMoved(moved.old, row.old)
            let newMoved = isMoved(moved.new, row.new)
            if row.kind != .context, oldMoved || newMoved, row.kind != .modified || (oldMoved && newMoved) {
                model.splitRows[index].isMoved = true
            }
        }
        return model
    }
}

public import AemiText

/// What a line of the new side did relative to the old side: the marks an editor gutter shows next to a buffer.
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
public enum LineChange: Sendable, Hashable {
    case added
    case modified
    /// Lines of the old side were removed just above this one (or, for the last line, at the end).
    case deleted

    /// When two changes land on one line, the more consequential one shows: a deletion over a modification over an
    /// addition.
    var priority: Int {
        switch self {
            case .deleted: 3
            case .modified: 2
            case .added: 1
        }
    }
}

/// The changes of the new side, keyed by its line index, from an edit script.
///
/// Every run of edits between two equal lines is one change: the removed and inserted lines pair up in order as
/// modifications, surplus inserted lines are additions, and surplus removed lines leave one deletion mark on the
/// line that follows them (the last line when nothing follows). A line that collects more than one mark keeps the
/// one with the higher ``LineChange/priority``.
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
public struct LineChangeMarkers: Sendable, Equatable {
    public static let empty = LineChangeMarkers(byLine: [:])

    public let byLine: [Int: LineChange]

    public init(byLine: [Int: LineChange]) {
        self.byLine = byLine
    }

    public var isEmpty: Bool { byLine.isEmpty }

    /// - Parameters:
    ///   - edits: The edit script from the old side to the new side, in order.
    ///   - newLineCount: The number of lines on the new side, which bounds the deletion anchor.
    /// - Complexity: O(edits)
    public init(edits: [DiffEdit], newLineCount: Int) {
        var markers: [Int: LineChange] = [:]
        var runStart = 0
        var removed = 0
        var inserted = 0
        func closeRun() {
            guard removed > 0 || inserted > 0 else { return }
            let paired = min(removed, inserted)
            for offset in 0 ..< paired {
                Self.mark(.modified, at: runStart + offset, in: &markers)
            }
            for offset in paired ..< inserted {
                Self.mark(.added, at: runStart + offset, in: &markers)
            }
            if removed > inserted, newLineCount > 0 {
                Self.mark(.deleted, at: min(runStart + paired, newLineCount - 1), in: &markers)
            }
            removed = 0
            inserted = 0
        }
        for edit in edits {
            switch edit {
                case .equal(_, let newIndex):
                    closeRun()
                    runStart = newIndex + 1
                case .delete:
                    removed += 1
                case .insert(let newIndex):
                    if inserted == 0, removed == 0 { runStart = newIndex }
                    inserted += 1
            }
        }
        closeRun()
        byLine = markers
    }

    /// The (old, new) line pairs the ``LineChange/modified`` marks stand for: within each run of edits, the removed
    /// and inserted lines pair up in order, so an intraline emphasis can compare exactly the lines the gutter
    /// marks as modified.
    /// - Complexity: O(edits)
    public static func modifiedPairs(edits: [DiffEdit]) -> [(old: Int, new: Int)] {
        var pairs: [(old: Int, new: Int)] = []
        var removed: [Int] = []
        var inserted: [Int] = []
        func closeRun() {
            for (oldIndex, newIndex) in zip(removed, inserted) {
                pairs.append((oldIndex, newIndex))
            }
            removed.removeAll(keepingCapacity: true)
            inserted.removeAll(keepingCapacity: true)
        }
        for edit in edits {
            switch edit {
                case .equal:
                    closeRun()
                case .delete(let oldIndex):
                    removed.append(oldIndex)
                case .insert(let newIndex):
                    inserted.append(newIndex)
            }
        }
        closeRun()
        return pairs
    }

    /// The markers between two line sources under `pipeline`.
    public init(old: some DiffSource, new: some DiffSource, pipeline: DiffPipeline = DiffPipeline()) {
        guard new.lineCount > 0 else {
            self = .empty
            return
        }
        self.init(edits: LineDiff.diffLines(old: old, new: new, pipeline: pipeline), newLineCount: new.lineCount)
    }

    private static func mark(_ change: LineChange, at line: Int, in markers: inout [Int: LineChange]) {
        if let existing = markers[line], existing.priority >= change.priority { return }
        markers[line] = change
    }
}

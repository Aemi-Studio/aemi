public import AemiText

/// One change of a diff: the old lines it removes and the new lines it adds, next to each other in the edit script;
/// either range may be empty.
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
public struct DiffChange: Sendable, Hashable {
    public let old: Range<Int>
    public let new: Range<Int>

    public init(old: Range<Int>, new: Range<Int>) {
        self.old = old
        self.new = new
    }
}

/// A diff's first phase (review §7.4, P1b): which lines match, and nothing drawn from their text. It is what a text
/// needs to be laid out; intraline emphasis (``IntralineEmphasis``) and moved blocks (``MovedBlocks``) refine it after.
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
public struct DiffStructure: Sendable {
    /// The edit script, refined by the pipeline's refiners.
    public let edits: [DiffEdit]
    /// Each run of deletions and insertions between equal lines, in order.
    public let changes: [DiffChange]
    /// Every line's interned identifier and indent, which the later phases read rather than hash the lines again.
    public let lines: LineDiffContext
    /// Whether the line diff found the script it looks for: false when a search settled at the cost limit, or a
    /// cancellation stopped it, which leaves a valid script that may not be the shortest.
    public let isMinimal: Bool

    public init(edits: [DiffEdit], lines: LineDiffContext, isMinimal: Bool) {
        self.edits = edits
        self.lines = lines
        self.isMinimal = isMinimal
        changes = Self.changes(of: edits)
    }

    /// The runs of deletions and insertions of `edits`.
    /// - Complexity: O(edits)
    static func changes(of edits: [DiffEdit]) -> [DiffChange] {
        var changes: [DiffChange] = []
        var old = 0
        var new = 0
        var start: (old: Int, new: Int)?
        func close() {
            guard let open = start else { return }
            changes.append(DiffChange(old: open.old ..< old, new: open.new ..< new))
            start = nil
        }
        for edit in edits {
            switch edit {
                case .equal(let oldIndex, let newIndex):
                    close()
                    old = oldIndex + 1
                    new = newIndex + 1
                case .delete(let oldIndex):
                    if start == nil { start = (old, new) }
                    old = oldIndex + 1
                case .insert(let newIndex):
                    if start == nil { start = (old, new) }
                    new = newIndex + 1
            }
        }
        close()
        return changes
    }
}

@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
extension LineDiff {
    /// A diff's structure: `old` and `new` interned under the pipeline's whitespace mode, the line diff run over the
    /// identifiers within `limits`, then refined by every stage the pipeline wires in.
    ///
    /// Myers looks for the task's cancellation every 64 rounds of a search; a cancelled task gets no structure.
    /// - Throws: `CancellationError` when the calling task is cancelled.
    /// - Complexity: O(bytes) to intern, plus the line diff's own cost, which `limits.costLimit` bounds.
    public static func structure(
        old: some LineSource, new: some LineSource, pipeline: DiffPipeline = DiffPipeline(),
        limits: DiffLimits = DiffLimits()
    ) async throws(CancellationError) -> DiffStructure {
        try checkCancellation()
        let structure = makeStructure(old: old, new: new, pipeline: pipeline, limits: limits)
        try checkCancellation()
        return structure
    }

    /// ``structure(old:new:pipeline:limits:)`` from synchronous code.
    static func makeStructure(
        old: some LineSource, new: some LineSource, pipeline: DiffPipeline, limits: DiffLimits
    ) -> DiffStructure {
        var interner = LineInterner(whitespace: pipeline.whitespace)
        let oldLines = interner.intern(old)
        let newLines = interner.intern(new)
        let context = LineDiffContext(
            old: oldLines.identifiers, new: newLines.identifiers, oldIndents: oldLines.indents,
            newIndents: newLines.indents)
        let result = pipeline.lineDiff.diff(context.old, context.new, limits: limits)
        var edits = result.edits
        for refiner in pipeline.refiners {
            edits = refiner.refine(edits, lines: context)
        }
        return DiffStructure(edits: edits, lines: context, isMinimal: result.isMinimal)
    }

    private static func checkCancellation() throws(CancellationError) {
        if Task.isCancelled { throw CancellationError() }
    }
}

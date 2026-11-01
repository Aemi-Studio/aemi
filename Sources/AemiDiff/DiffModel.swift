public import AemiLexers
import AemiText

/// A syntax token provider that can return ranges for only the lines paired by a diff.
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
public protocol SelectedSyntaxTokenRanging: SyntaxTokenRanging {
    /// - Parameters:
    ///   - text: The whole side, lines separated by `\n`.
    ///   - language: The language the text is written in.
    ///   - lineIndices: Indices of paired lines whose UTF-16 token ranges are needed; invalid indices are ignored.
    /// - Returns: Ranges relative to each valid requested line, keyed by its zero-based index.
    /// - Complexity: O(text + returned ranges), excluding parsing.
    func tokenRangesByLine(text: String, language: Language, lineIndices: [Int]) -> [Int: [Range<Int>]]
}

@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
public enum RowKind: Sendable {
    case context
    case added
    case removed
    /// A changed line that has a counterpart on the other side; used by the split view only.
    case modified
    /// Empty space that keeps the two panes of the split view aligned.
    case filler
    /// A file name introducing that file's hunks when several files are shown together.
    case header
}

/// A line of one side of the diff with the units to emphasize inside it.
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
public struct DiffLineRef: Sendable, Equatable {
    public let index: Int
    public let emphasis: [Range<Int>]

    public init(index: Int, emphasis: [Range<Int>] = []) {
        self.index = index
        self.emphasis = emphasis
    }
}

/// One row of a rendered diff. In the unified layout a row shows either side or both (context);
/// in the split layout the old side is drawn on the left and the new side on the right.
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
public struct DiffRow: Sendable, Equatable {
    public let kind: RowKind
    public let old: DiffLineRef?
    public let new: DiffLineRef?
    /// The line only moved: it was removed here and added unchanged elsewhere, or the reverse.
    public var isMoved = false

    public init(kind: RowKind, old: DiffLineRef?, new: DiffLineRef?, isMoved: Bool = false) {
        self.kind = kind
        self.old = old
        self.new = new
        self.isMoved = isMoved
    }
}

/// A diff between two texts, laid out both as a unified sequence and as aligned split rows.
///
/// It is the composition of the diff's phases (review §7.4, P1b): ``init(structure:pairs:oldText:newText:)`` lays the
/// rows out from the structure and the pairs, then `applying(_:)` adds the intraline emphasis of some changes, or marks
/// the moved lines. The text initializer runs them all.
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
public struct DiffModel: Sendable {
    public let oldText: String
    public let newText: String
    public let oldLines: [Substring]
    public let newLines: [Substring]
    /// The structure the rows are laid out from.
    public let structure: DiffStructure
    /// Each change's pairs, by change index: which removed line each added line of the change replaces.
    public let changePairs: [[LinePair]]
    public internal(set) var unifiedRows: [DiffRow]
    public internal(set) var splitRows: [DiffRow]
    /// Indices of the first row of each change, per layout.
    public let unifiedChangeStarts: [Int]
    public let splitChangeStarts: [Int]
    /// Row ranges of each change, per layout.
    public let unifiedChangeRanges: [Range<Int>]
    public let splitChangeRanges: [Range<Int>]

    /// - Parameters:
    ///   - oldText: The left side, split into lines on `\n`.
    ///   - newText: The right side, split into lines on `\n`.
    ///   - granularity: Unit of change for the emphasis inside paired lines.
    ///   - language: Drives the syntax tier's tokenizer; ignored by the other tiers.
    ///   - pipeline: The stages the diff goes through; the default wires every heuristic in.
    ///   - tokenRanges: Token boundaries for the syntax tier; ``CodeTokenRanges`` when no parser is wanted.
    ///   - limits: The bounds every phase keeps to.
    public init(
        oldText: String,
        newText: String,
        granularity: IntralineGranularity = .character,
        language: Language = .plain,
        pipeline: DiffPipeline = DiffPipeline(),
        tokenRanges: any SyntaxTokenRanging,
        limits: DiffLimits = DiffLimits()
    ) {
        self.init(structureOf: oldText, newText: newText, pipeline: pipeline, limits: limits)
        let oldLines = self.oldLines
        let newLines = self.newLines
        let changes = structure.changes
        let tokens = SyntaxTokenSource(provider: tokenRanges, language: language, oldText: oldText, newText: newText)
        let options = IntralineEmphasis.Options(
            granularity: granularity, refiners: pipeline.intralineRefiners, tokens: tokens, limits: limits)
        let emphasis = IntralineEmphasis.emphasize(
            Array(changes.indices), of: changes, pairs: changePairs, options: options,
            isCancelled: { false }, units: { isOld, index in Array((isOld ? oldLines[index] : newLines[index]).utf16) })
        if let emphasis { self = applying(emphasis) }
        if pipeline.detectsMovedBlocks { self = applying(MovedBlocks.detect(in: structure, limits: limits)) }
    }

    /// The first phase alone, from synchronous code: the rows of the two texts, with each change's pairs, and neither
    /// emphasis nor moved lines, which ``applying(_:)`` adds as they are found. What a text needs to be drawn first.
    /// - Parameters:
    ///   - oldText: The left side, split into lines on `\n`.
    ///   - newText: The right side, split into lines on `\n`.
    ///   - pipeline: The stages the diff goes through; its pairing pairs each change's lines.
    ///   - limits: The bounds the line diff and the pairing keep to.
    public init(
        structureOf oldText: String, newText: String, pipeline: DiffPipeline = DiffPipeline(),
        limits: DiffLimits = DiffLimits()
    ) {
        let old = TextLines(oldText)
        let new = TextLines(newText)
        let structure = LineDiff.makeStructure(old: old, new: new, pipeline: pipeline, limits: limits)
        let oldLines = Self.substrings(of: old)
        let newLines = Self.substrings(of: new)
        let pairs = structure.changes.map { change in
            Self.pairs(
                removed: Array(oldLines[change.old]), added: Array(newLines[change.new]), pairing: pipeline.pairing,
                limits: limits)
        }
        self.init(
            structure: structure, pairs: pairs, oldText: old.text, newText: new.text, oldLines: oldLines,
            newLines: newLines)
    }

    /// The rows of `structure`, with each change's pairs in the split layout and no emphasis yet: what a text needs to
    /// be drawn.
    /// - Parameters:
    ///   - structure: The diff of `oldText` and `newText`.
    ///   - pairs: Each change's pairs, by change index, as ``IntralineEmphasis/pairs(of:old:new:pairing:limits:)``
    ///     gives them.
    ///   - oldText: The left side.
    ///   - newText: The right side.
    public init(structure: DiffStructure, pairs: [[LinePair]], oldText: String, newText: String) {
        self.init(
            structure: structure, pairs: pairs, oldText: oldText, newText: newText, oldLines: Self.lines(of: oldText),
            newLines: Self.lines(of: newText))
    }

    private init(
        structure: DiffStructure, pairs: [[LinePair]], oldText: String, newText: String, oldLines: [Substring],
        newLines: [Substring]
    ) {
        self.oldText = oldText
        self.newText = newText
        self.oldLines = oldLines
        self.newLines = newLines
        self.structure = structure
        changePairs = pairs
        var unified: [DiffRow] = []
        var split: [DiffRow] = []
        unified.reserveCapacity(max(oldLines.count, newLines.count))
        split.reserveCapacity(max(oldLines.count, newLines.count))
        var unifiedRanges: [Range<Int>] = []
        var splitRanges: [Range<Int>] = []
        var next = 0
        var inChange = false
        for edit in structure.edits {
            guard case .equal(let old, let new) = edit else {
                if !inChange, next < structure.changes.count {
                    inChange = true
                    let ranges = Self.appendRows(
                        of: structure.changes[next], pairs: next < pairs.count ? pairs[next] : [], unified: &unified,
                        split: &split)
                    unifiedRanges.append(ranges.unified)
                    splitRanges.append(ranges.split)
                    next += 1
                }
                continue
            }
            inChange = false
            let row = DiffRow(kind: .context, old: DiffLineRef(index: old), new: DiffLineRef(index: new))
            unified.append(row)
            split.append(row)
        }
        unifiedRows = unified
        splitRows = split
        unifiedChangeRanges = unifiedRanges
        splitChangeRanges = splitRanges
        unifiedChangeStarts = unifiedRanges.map(\.lowerBound)
        splitChangeStarts = splitRanges.map(\.lowerBound)
    }

    /// Appends one change's rows: in the unified layout its removed lines then its added ones, in the split layout one
    /// row per pair. Returns the rows it took in each.
    private static func appendRows(
        of change: DiffChange, pairs: [LinePair], unified: inout [DiffRow], split: inout [DiffRow]
    ) -> (unified: Range<Int>, split: Range<Int>) {
        let unifiedStart = unified.count
        let splitStart = split.count
        for index in change.old { unified.append(DiffRow(kind: .removed, old: DiffLineRef(index: index), new: nil)) }
        for index in change.new { unified.append(DiffRow(kind: .added, old: nil, new: DiffLineRef(index: index))) }
        for pair in pairs {
            let old = pair.old.map { DiffLineRef(index: change.old.lowerBound + $0) }
            let new = pair.new.map { DiffLineRef(index: change.new.lowerBound + $0) }
            let kind: RowKind =
                switch (old, new) {
                    case (.some, .some): .modified
                    case (.some, .none): .removed
                    default: .added
                }
            split.append(DiffRow(kind: kind, old: old, new: new))
        }
        return (unifiedStart ..< unified.count, splitStart ..< split.count)
    }

    /// The pairs of one change's `removed` and `added` lines under `pairing`, positional past `limits.maximumPairs`.
    static func pairs(removed: [Substring], added: [Substring], pairing: any LinePairing, limits: DiffLimits)
        -> [LinePair]
    {
        guard !removed.isEmpty, !added.isEmpty, removed.count * added.count <= limits.maximumPairs else {
            return PositionalPairing.pairs(removed: removed.count, added: added.count)
        }
        return pairing.pairs(removed: removed, added: added, limits: limits)
    }

    /// Splits on "\n" bytes, since Swift folds "\r\n" into one Character, drops a trailing "\r" per line so CRLF files
    /// align, and ignores the empty tail after a final newline. The line breaks are found with `memchr` (perf-core
    /// D3), as ``TextLines`` finds them.
    ///
    /// A lone carriage return does not end a line, matching git and the other line splitter (``TextLines``); the
    /// renderer's line ranges rely on this cut rather than make their own, so line numbers agree everywhere. A file
    /// that uses only carriage returns therefore shows as one long line; normalising such files belongs at load time,
    /// not here.
    public static func lines(of text: String) -> [Substring] {
        substrings(of: TextLines(text))
    }

    /// Each line of `lines` as a substring of its text.
    /// - Complexity: O(lines), stepping through the text's UTF-8 from one line to the next.
    static func substrings(of lines: TextLines) -> [Substring] {
        let utf8 = lines.text.utf8
        var result: [Substring] = []
        result.reserveCapacity(lines.lineCount)
        var cursor = utf8.startIndex
        var offset = 0
        for range in lines.lineRanges {
            let start = utf8.index(cursor, offsetBy: range.lowerBound - offset)
            let end = utf8.index(start, offsetBy: range.count)
            result.append(Substring(utf8[start ..< end]))
            cursor = end
            offset = range.upperBound
        }
        return result
    }
}

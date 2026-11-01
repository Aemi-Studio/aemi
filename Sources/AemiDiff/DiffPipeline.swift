/// Which heuristics a diff uses, as the user sets them; every flag maps to one stage of the pipeline.
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
public struct DiffHeuristics: Sendable, Equatable, Hashable, Codable {
    /// Match rare lines first (git's histogram algorithm) instead of the plain shortest edit script. Off by default:
    /// the shortest script is what most tools show, anchoring is there for repetitive files.
    public var anchorsRareLines = false
    /// Slide change boundaries to where git's indent heuristic scores best.
    public var slidesToIndentation = true
    /// Pair changed lines by similarity rather than by position, so emphasis lands on the right counterpart.
    public var pairsSimilarLines = true
    /// Merge scattered intraline edits and align them to token boundaries, the way diff-match-patch cleans up.
    public var cleansUpEmphasis = true
    /// Mark blocks of lines that only moved.
    public var detectsMovedBlocks = true
    public var whitespace = WhitespaceMode.exact

    public init(
        anchorsRareLines: Bool = false, slidesToIndentation: Bool = true, pairsSimilarLines: Bool = true,
        cleansUpEmphasis: Bool = true, detectsMovedBlocks: Bool = true, whitespace: WhitespaceMode = .exact
    ) {
        self.anchorsRareLines = anchorsRareLines
        self.slidesToIndentation = slidesToIndentation
        self.pairsSimilarLines = pairsSimilarLines
        self.cleansUpEmphasis = cleansUpEmphasis
        self.detectsMovedBlocks = detectsMovedBlocks
        self.whitespace = whitespace
    }

    /// Every heuristic off: the plain shortest edit script with positional pairing.
    public static let none = DiffHeuristics(
        anchorsRareLines: false, slidesToIndentation: false, pairsSimilarLines: false, cleansUpEmphasis: false,
        detectsMovedBlocks: false
    )
}

/// How whitespace takes part in deciding whether two lines are the same.
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
public enum WhitespaceMode: String, Sendable, CaseIterable, Codable, Identifiable {
    case exact
    /// Trailing whitespace is ignored.
    case ignoreTrailing
    /// Leading and trailing whitespace are ignored, so re-indented lines read as unchanged.
    case ignoreLeadingAndTrailing
    /// Every whitespace difference is ignored.
    case ignoreAll

    public var id: String { rawValue }

    /// The key two lines are compared by.
    public func normalized(_ line: Substring) -> Substring {
        let utf8 = line.utf8
        switch self {
            case .exact:
                return line
            case .ignoreTrailing:
                var end = utf8.endIndex
                while end > utf8.startIndex, Self.isSpace(utf8[utf8.index(before: end)]) {
                    end = utf8.index(before: end)
                }
                return Substring(utf8[utf8.startIndex ..< end])
            case .ignoreLeadingAndTrailing:
                var start = utf8.startIndex
                while start < utf8.endIndex, Self.isSpace(utf8[start]) { start = utf8.index(after: start) }
                var end = utf8.endIndex
                while end > start, Self.isSpace(utf8[utf8.index(before: end)]) { end = utf8.index(before: end) }
                return Substring(utf8[start ..< end])
            case .ignoreAll:
                return Substring(String(decoding: utf8.filter { !Self.isSpace($0) }, as: UTF8.self))
        }
    }

    static func isSpace(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t") || byte == UInt8(ascii: "\r")
    }
}

/// The stages a diff goes through, composed from heuristics so any of them can be wired out.
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
public struct DiffPipeline: Sendable {
    public var lineDiff: any LineDiffing
    public var refiners: [any EditScriptRefining]
    public var pairing: any LinePairing
    public var intralineRefiners: [any IntralineRefining]
    public var whitespace: WhitespaceMode
    public var detectsMovedBlocks: Bool

    public init(
        lineDiff: any LineDiffing = MyersLineDiff(),
        refiners: [any EditScriptRefining] = [IndentHeuristic()],
        pairing: any LinePairing = SimilarityPairing(),
        intralineRefiners: [any IntralineRefining] = [SemanticCleanup()],
        whitespace: WhitespaceMode = .exact,
        detectsMovedBlocks: Bool = true
    ) {
        self.lineDiff = lineDiff
        self.refiners = refiners
        self.pairing = pairing
        self.intralineRefiners = intralineRefiners
        self.whitespace = whitespace
        self.detectsMovedBlocks = detectsMovedBlocks
    }

    public init(heuristics: DiffHeuristics) {
        self.init(
            lineDiff: heuristics.anchorsRareLines ? HistogramLineDiff() : MyersLineDiff(),
            refiners: heuristics.slidesToIndentation ? [IndentHeuristic()] : [],
            pairing: heuristics.pairsSimilarLines ? SimilarityPairing() : PositionalPairing(),
            intralineRefiners: heuristics.cleansUpEmphasis ? [SemanticCleanup()] : [],
            whitespace: heuristics.whitespace,
            detectsMovedBlocks: heuristics.detectsMovedBlocks
        )
    }
}

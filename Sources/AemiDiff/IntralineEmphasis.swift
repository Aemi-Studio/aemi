public import AemiLexers
public import AemiText

/// Where the syntax granularity of intraline emphasis reads token boundaries: a side's lines, by index, as UTF-16
/// ranges from each line's start.
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
public protocol IntralineTokenSource: Sendable {
    /// The token ranges of the lines of `lineIndices` on the old side, or the new one; a missing line is compared by
    /// words and code tokens.
    func tokenRanges(onOldSide: Bool, lineIndices: [Int]) -> [Int: [Range<Int>]]
}

/// A ``SyntaxTokenRanging`` provider over the two texts of a diff, asked once per side for every line the emphasis
/// needs. GitDiffViewer's Swift provider reads the syntax facts store, so a side parsed for colour is not parsed again.
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
public struct SyntaxTokenSource: IntralineTokenSource {
    public let provider: any SyntaxTokenRanging
    public let language: Language
    public let oldText: String
    public let newText: String

    public init(provider: any SyntaxTokenRanging, language: Language, oldText: String, newText: String) {
        self.provider = provider
        self.language = language
        self.oldText = oldText
        self.newText = newText
    }

    public func tokenRanges(onOldSide: Bool, lineIndices: [Int]) -> [Int: [Range<Int>]] {
        let text = onOldSide ? oldText : newText
        if let provider = provider as? any SelectedSyntaxTokenRanging {
            return provider.tokenRangesByLine(text: text, language: language, lineIndices: lineIndices)
        }
        let byLine = provider.tokenRangesByLine(text: text, language: language)
        var selected: [Int: [Range<Int>]] = [:]
        selected.reserveCapacity(lineIndices.count)
        for index in lineIndices where index >= 0 && index < byLine.count {
            selected[index] = byLine[index]
        }
        return selected
    }
}

/// The emphasis inside one paired line: UTF-16 ranges of the old line's removed units and the new line's added ones.
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
public struct LineEmphasis: Sendable, Equatable {
    public let old: [Range<Int>]
    public let new: [Range<Int>]

    public init(old: [Range<Int>], new: [Range<Int>]) {
        self.old = old
        self.new = new
    }
}

/// The emphasis of one change: one entry per pair of its pairing, nil where the pair has one side, or its lines are
/// too long or too different for emphasis to help.
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
public struct ChangeEmphasis: Sendable, Equatable {
    public let lines: [LineEmphasis?]

    public init(lines: [LineEmphasis?]) {
        self.lines = lines
    }
}

/// A diff's second phase (review §7.4, P1b): which removed line each added line replaces, then the emphasis inside
/// each pair, for the changes asked for, visible ones first, so a screen's emphasis costs a screen's pairs.
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
public enum IntralineEmphasis {
    /// Which removed line of `change` each added line replaces, as indices from the change's first lines: what the split
    /// layout's rows hold. A change past `limits.maximumPairs` pairs by position without reading its lines.
    /// - Complexity: O(removed × added × line length) for similarity pairing, O(lines) by position.
    public static func pairs(
        of change: DiffChange,
        old: some LineSource,
        new: some LineSource,
        pairing: any LinePairing,
        limits: DiffLimits = DiffLimits()
    ) -> [LinePair] {
        guard !change.old.isEmpty, !change.new.isEmpty, change.old.count * change.new.count <= limits.maximumPairs
        else { return PositionalPairing.pairs(removed: change.old.count, added: change.new.count) }
        return pairing.pairs(
            removed: change.old.map { Substring(old.string(at: $0)) },
            added: change.new.map { Substring(new.string(at: $0)) },
            limits: limits
        )
    }

    /// The emphasis of each change of `changes`, indices into `structure.changes`, in the order given.
    /// - Parameters:
    ///   - changes: The changes to emphasize, visible ones first.
    ///   - structure: The diff's structure.
    ///   - pairs: Every change's pairs, as ``pairs(of:old:new:pairing:limits:)`` gives them, by change index.
    ///   - old: The old side's lines.
    ///   - new: The new side's lines.
    ///   - granularity: The unit two lines are compared in.
    ///   - refiners: Cleanup stages applied to each pair's token-level script.
    ///   - tokens: Token boundaries for the syntax granularity; words and code tokens without them.
    ///   - limits: The longest line compared.
    /// - Returns: Each requested change's emphasis, by change index.
    /// - Throws: `CancellationError` when the calling task is cancelled; it is looked for between changes.
    public static func emphasis(
        for changes: [Int],
        in structure: DiffStructure,
        pairs: [[LinePair]],
        old: some LineSource,
        new: some LineSource,
        granularity: IntralineGranularity,
        refiners: [any IntralineRefining] = [],
        tokens: (any IntralineTokenSource)? = nil,
        limits: DiffLimits = DiffLimits()
    ) async throws(CancellationError) -> [Int: ChangeEmphasis] {
        let emphasis = emphasize(
            changes,
            of: structure.changes,
            pairs: pairs,
            options: Options(granularity: granularity, refiners: refiners, tokens: tokens, limits: limits),
            isCancelled: { Task.isCancelled },
            units: { isOld, index in Array((isOld ? old.string(at: index) : new.string(at: index)).utf16) }
        )
        guard let emphasis else { throw CancellationError() }
        return emphasis
    }

    /// How pairs are compared: the granularity, the cleanup, the syntax tier's boundaries and the longest line.
    struct Options {
        let granularity: IntralineGranularity
        let refiners: [any IntralineRefining]
        let tokens: (any IntralineTokenSource)?
        let limits: DiffLimits
    }

    /// ``emphasis(for:in:pairs:old:new:granularity:refiners:tokens:limits:)`` over lines `units` gives as UTF-16
    /// units; nil once `isCancelled` says so.
    static func emphasize(
        _ requested: [Int],
        of changes: [DiffChange],
        pairs: [[LinePair]],
        options: Options,
        isCancelled: () -> Bool,
        units: (_ isOld: Bool, _ index: Int) -> [UInt16]
    ) -> [Int: ChangeEmphasis]? {
        let granularity = options.granularity
        let tokens = options.tokens
        let limits = options.limits
        let refiners = options.refiners
        // Every pair's units, read once, and the lines short enough to compare.
        var pairUnits: [Int: [(old: [UInt16], new: [UInt16])?]] = [:]
        var oldIndices: [Int] = []
        var newIndices: [Int] = []
        for change in requested {
            guard !isCancelled() else { return nil }
            pairUnits[change] = pairs[change]
                .map { pair -> (old: [UInt16], new: [UInt16])? in
                    guard let oldOffset = pair.old, let newOffset = pair.new else { return nil }
                    let oldIndex = changes[change].old.lowerBound + oldOffset
                    let newIndex = changes[change].new.lowerBound + newOffset
                    let lines = (old: units(true, oldIndex), new: units(false, newIndex))
                    let longest = limits.maximumIntralineUnits
                    guard lines.old.count <= longest, lines.new.count <= longest else { return nil }
                    oldIndices.append(oldIndex)
                    newIndices.append(newIndex)
                    return lines
                }
        }
        // The syntax tier's boundaries for every compared line, asked for once per side, and not at all when no line
        // is compared: a Swift provider parses the side it is asked about.
        let asksTokens = granularity == .syntax && !oldIndices.isEmpty
        let oldTokens = asksTokens ? tokens?.tokenRanges(onOldSide: true, lineIndices: oldIndices) : nil
        let newTokens = asksTokens ? tokens?.tokenRanges(onOldSide: false, lineIndices: newIndices) : nil
        var emphasis: [Int: ChangeEmphasis] = [:]
        emphasis.reserveCapacity(requested.count)
        for change in requested {
            guard !isCancelled() else { return nil }
            let lines = zip(pairs[change], pairUnits[change] ?? [])
                .map { pair, lines -> LineEmphasis? in
                    guard let lines, let oldOffset = pair.old, let newOffset = pair.new else { return nil }
                    let oldIndex = changes[change].old.lowerBound + oldOffset
                    let newIndex = changes[change].new.lowerBound + newOffset
                    return
                        IntralineDiff.emphasis(
                            oldUnits: lines.old,
                            newUnits: lines.new,
                            granularity: granularity,
                            oldTokens: oldTokens?[oldIndex],
                            newTokens: newTokens?[newIndex],
                            refiners: refiners
                        )
                        .map { LineEmphasis(old: $0.old, new: $0.new) }
                }
            emphasis[change] = ChangeEmphasis(lines: lines)
        }
        return emphasis
    }
}

@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
extension PositionalPairing {
    /// The positional pairs of `removed` removed and `added` added lines, which read no line.
    static func pairs(removed: Int, added: Int) -> [LinePair] {
        (0 ..< max(removed, added)).map { LinePair(old: $0 < removed ? $0 : nil, new: $0 < added ? $0 : nil) }
    }
}

@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
extension LineSource {
    /// Line `index` decoded as a string, a repair character standing for any invalid UTF-8.
    func string(at index: Int) -> String {
        withLineBytes(at: index) { bytes in bytes.withUnsafeBufferPointer { String(decoding: $0, as: UTF8.self) } }
    }
}

/// The bounds every phase of a diff keeps to (review §7.4, P1b), so no input makes a phase run away: past a bound a
/// phase settles for a valid result that is less refined, never for a failure.
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
public struct DiffLimits: Sendable, Hashable {
    /// Rounds a middle-snake search may take before it splits its problem heuristically; nil takes
    /// `max(256, 4 × √(lines))` per search (perf-core D2). Past it the script stays valid but may not be the shortest.
    public var costLimit: Int?
    /// Set aside the lines found on one side only before Myers runs: they can never match, so the script stays as
    /// short while the search runs on a smaller problem (perf-core D1, git's `xdl_cleanup_records`).
    public var discardsUnmatchedLines: Bool
    /// The longest line, in UTF-16 units, that intraline emphasis compares, or that similarity pairing reads
    /// (Core S13): a longer line gets no emphasis anyway.
    public var maximumIntralineUnits: Int
    /// The most removed × added lines one change may hold for similarity pairing; a larger change pairs by position.
    public var maximumPairs: Int
    /// A line with more candidates than this on the removed side starts no moved block, as a histogram anchor does
    /// not (perf-core D6): a long run of `}` would otherwise compare every candidate with every other.
    public var maximumMovedCandidates: Int

    public init(
        costLimit: Int? = nil, discardsUnmatchedLines: Bool = true,
        maximumIntralineUnits: Int = IntralineDiff.maximumLineLength, maximumPairs: Int = 40_000,
        maximumMovedCandidates: Int = 64
    ) {
        self.costLimit = costLimit
        self.discardsUnmatchedLines = discardsUnmatchedLines
        self.maximumIntralineUnits = maximumIntralineUnits
        self.maximumPairs = maximumPairs
        self.maximumMovedCandidates = maximumMovedCandidates
    }
}

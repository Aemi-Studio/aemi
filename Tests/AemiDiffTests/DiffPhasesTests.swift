import AemiTestKit
import AemiText
import Synchronization
import Testing

@testable import AemiDiff

/// The diff in phases (P1b): the structure, the pairs and emphasis of the changes asked for, and the moved lines, each
/// within `DiffLimits`, composing to the model the text initializer builds.
struct DiffPhasesTests {
    // Three lines move below a block of six, which stays, and the last line is renamed.
    private static let old = """
        let a = 1
        let b = 2
        let c = 3
        first()
        second()
        third()
        fourth()
        fifth()
        sixth()
        let renamed = value
        """
    private static let new = """
        first()
        second()
        third()
        fourth()
        fifth()
        sixth()
        let a = 1
        let b = 2
        let c = 3
        let renamedAgain = value
        """

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    private static func structure(limits: DiffLimits = DiffLimits()) async throws -> DiffStructure {
        try await LineDiff.structure(old: TextLines(old), new: TextLines(new), limits: limits)
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `the structure holds the pipeline's script and each run of deletions and insertions`() async throws {
        let structure = try await Self.structure()

        #expect(structure.edits == LineDiff.diffLines(DiffModel.lines(of: Self.old), DiffModel.lines(of: Self.new)))
        #expect(structure.changes == DiffStructure.changes(of: structure.edits))
        #expect(structure.isMinimal)
        #expect(structure.changes == [DiffChange(old: 0 ..< 3, new: 0 ..< 0), DiffChange(old: 9 ..< 10, new: 6 ..< 10)])
        #expect(structure.lines.old.count == 10)
        for change in structure.changes {
            #expect(!change.old.isEmpty || !change.new.isEmpty)
        }
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `a cost limit that cuts the search short leaves a valid script that says it may not be the shortest`()
        async throws
    {
        let old = (0 ..< 400).map { "old \($0)" }.joined(separator: "\n")
        let new = (0 ..< 400).map { $0.isMultiple(of: 2) ? "old \($0)" : "new \($0)" }.joined(separator: "\n")

        let structure = try await LineDiff.structure(
            old: TextLines(old), new: TextLines(new), limits: DiffLimits(costLimit: 1, discardsUnmatchedLines: false))

        #expect(!structure.isMinimal)
        #expect(Self.reconstructs(structure.edits, old: 400, new: 400))
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `without discarding unmatched lines the script is as short`() async throws {
        let kept = try await Self.structure(limits: DiffLimits(discardsUnmatchedLines: false))
        let discarded = try await Self.structure()

        #expect(Self.editCount(kept.edits) == Self.editCount(discarded.edits))
        #expect(Self.reconstructs(kept.edits, old: 10, new: 10))
    }

    /// The structure, asked for from a task that is cancelled first.
    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    private static func cancelledStructure() async throws -> DiffStructure {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await structure()
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `a cancelled task gets no structure`() async {
        // A child task, so cancelling the task the diff runs in leaves the test's own alone.
        async let attempt = Self.cancelledStructure()
        do {
            _ = try await attempt
            Issue.record("a cancelled task got a structure")
        } catch {
            #expect(error is CancellationError)
        }
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `the phases compose to the model the text initializer builds`() async throws {
        let full = DiffModel(
            oldText: Self.old, newText: Self.new, granularity: .word, tokenRanges: CodeTokenRanges())
        let old = TextLines(Self.old)
        let new = TextLines(Self.new)
        let pipeline = DiffPipeline()
        let structure = try await LineDiff.structure(old: old, new: new, pipeline: pipeline)
        let pairs = structure.changes.map {
            IntralineEmphasis.pairs(of: $0, old: old, new: new, pairing: pipeline.pairing)
        }
        let emphasis = try await IntralineEmphasis.emphasis(
            for: Array(structure.changes.indices), in: structure, pairs: pairs, old: old, new: new, granularity: .word,
            refiners: pipeline.intralineRefiners)

        let composed = DiffModel(structure: structure, pairs: pairs, oldText: Self.old, newText: Self.new)
            .applying(emphasis).applying(MovedBlocks.detect(in: structure))

        #expect(composed.unifiedRows == full.unifiedRows)
        #expect(composed.splitRows == full.splitRows)
        #expect(composed.splitRows.contains { $0.isMoved })
        #expect(composed.splitRows.contains { !($0.new?.emphasis ?? []).isEmpty })
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `the structure alone lays the rows out as the whole model does, with neither emphasis nor moved lines`() {
        let full = DiffModel(oldText: Self.old, newText: Self.new, granularity: .word, tokenRanges: CodeTokenRanges())

        let structural = DiffModel(structureOf: Self.old, newText: Self.new)

        #expect(structural.structure.edits == full.structure.edits)
        #expect(structural.changePairs == full.changePairs)
        #expect(structural.splitRows.map(\.kind) == full.splitRows.map(\.kind))
        #expect(structural.splitRows.allSatisfy { !$0.isMoved && ($0.new?.emphasis ?? []).isEmpty })
        #expect(full.splitRows.contains { $0.isMoved })
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `emphasis for one change leaves the others' rows plain`() async throws {
        let old = TextLines(Self.old)
        let new = TextLines(Self.new)
        let structure = try await LineDiff.structure(old: old, new: new)
        let pairs = structure.changes.map {
            IntralineEmphasis.pairs(of: $0, old: old, new: new, pairing: SimilarityPairing())
        }
        let plain = DiffModel(structure: structure, pairs: pairs, oldText: Self.old, newText: Self.new)
        let target = try #require(structure.changes.lastIndex { !$0.old.isEmpty && !$0.new.isEmpty })

        let emphasis = try await IntralineEmphasis.emphasis(
            for: [target], in: structure, pairs: pairs, old: old, new: new, granularity: .word)
        let model = plain.applying(emphasis)

        #expect(Array(emphasis.keys) == [target])
        let rows = model.splitChangeRanges[target]
        #expect(model.splitRows[rows].contains { !($0.new?.emphasis ?? []).isEmpty })
        for (index, range) in model.splitChangeRanges.enumerated() where index != target {
            #expect(model.splitRows[range] == plain.splitRows[range])
        }
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `the syntax granularity asks the token source once per side, for the compared lines only`() async throws {
        let old = TextLines(Self.old)
        let new = TextLines(Self.new)
        let structure = try await LineDiff.structure(old: old, new: new)
        let pairs = structure.changes.map {
            IntralineEmphasis.pairs(of: $0, old: old, new: new, pairing: SimilarityPairing())
        }
        let tokens = RecordingTokens()

        _ = try await IntralineEmphasis.emphasis(
            for: Array(structure.changes.indices), in: structure, pairs: pairs, old: old, new: new,
            granularity: .syntax, tokens: tokens)

        var pairedOld: [Int] = []
        var pairedNew: [Int] = []
        for (change, pairs) in zip(structure.changes, pairs) {
            for pair in pairs {
                guard let old = pair.old, let new = pair.new else { continue }
                pairedOld.append(change.old.lowerBound + old)
                pairedNew.append(change.new.lowerBound + new)
            }
        }
        #expect(pairedOld == [9])
        #expect(tokens.requests == [.init(isOld: true, lines: pairedOld), .init(isOld: false, lines: pairedNew)])

        // A change of added lines only compares none, and asks nothing.
        let unasked = RecordingTokens()
        let added = try await LineDiff.structure(old: TextLines("a"), new: TextLines("a\nb"))
        _ = try await IntralineEmphasis.emphasis(
            for: [0], in: added, pairs: [[LinePair(old: nil, new: 0)]], old: TextLines("a"), new: TextLines("a\nb"),
            granularity: .syntax, tokens: unasked)
        #expect(unasked.requests.isEmpty)
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `moved lines come from the interned identifiers, and a line with too many candidates starts no block`() {
        let structure = LineDiff.makeStructure(
            old: TextLines(Self.old), new: TextLines(Self.new), pipeline: DiffPipeline(), limits: DiffLimits())

        let moved = MovedBlocks.detect(in: structure)
        #expect(moved.old == [true, true, true] + Array(repeating: false, count: 7))
        #expect(moved.new == Array(repeating: false, count: 6) + [true, true, true, false])

        // The block's first line also stands alone on 100 other removed runs: past the cap it starts no block.
        let removed =
            (0 ..< 100).map { (index: $0 * 2, id: 7) } + [(index: 300, id: 7), (index: 301, id: 8), (index: 302, id: 9)]
        let added = [(index: 0, id: 7), (index: 1, id: 8), (index: 2, id: 9)]
        #expect(MovedBlocks.detect(removed: removed, added: added, maximumCandidates: 64).old.isEmpty)
        #expect(MovedBlocks.detect(removed: removed, added: added, maximumCandidates: 1_000).old == [300, 301, 302])
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `similarity pairing leaves a line longer than the intraline limit to position`() {
        let long = String(repeating: "abcdefgh", count: 300)
        let removed: [Substring] = ["x = 1", Substring(long)]
        let added: [Substring] = [Substring(long + "i"), "q := 22"]

        #expect(
            SimilarityPairing(maximumLineLength: 10_000).pairs(removed: removed, added: added)
                == [LinePair(old: 0, new: nil), LinePair(old: 1, new: 0), LinePair(old: nil, new: 1)])
        #expect(
            SimilarityPairing().pairs(removed: removed, added: added)
                == [LinePair(old: 0, new: 0), LinePair(old: 1, new: 1)])
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `the interner numbers lines in first-seen order whatever its seed`() {
        let lines: [Substring] = ["a", "b", "a", "c", "b", "d"]
        for seed: UInt64 in [0, 1, 0xDEAD_BEEF, .max] {
            var interner = LineInterner(whitespace: .exact, seed: seed)
            #expect(interner.intern(SubstringLines(lines)).identifiers == [0, 1, 0, 2, 1, 3])
        }
        // Enough distinct lines to grow the table several times.
        var interner = LineInterner(whitespace: .exact)
        let many = (0 ..< 5_000).map { Substring("line \($0 % 1_700)") }
        #expect(interner.intern(SubstringLines(many)).identifiers == (0 ..< 5_000).map { $0 % 1_700 })
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `the histogram over any hashable lines gives the script it gives their identifiers`() {
        var random = SeededRNG(seed: 0x4157)
        for _ in 0 ..< 200 {
            let old = (0 ..< random.int(in: 0 ... 30)).map { _ in random.int(in: 0 ... 6) }
            let new = (0 ..< random.int(in: 0 ... 30)).map { _ in random.int(in: 0 ... 6) }
            let script = LineDiff.diff(old, new, anchoringRareLines: true)
            #expect(
                LineDiff.diff(old.map { "line \($0)" }, new.map { "line \($0)" }, anchoringRareLines: true) == script)
            #expect(Self.reconstructs(script, old: old.count, new: new.count))
        }
    }

    /// Whether `edits` visits every old line once and every new line once, in order.
    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    private static func reconstructs(_ edits: [DiffEdit], old: Int, new: Int) -> Bool {
        var nextOld = 0
        var nextNew = 0
        for edit in edits {
            switch edit {
                case .equal(let oldIndex, let newIndex):
                    guard oldIndex == nextOld, newIndex == nextNew else { return false }
                    nextOld += 1
                    nextNew += 1
                case .delete(let oldIndex):
                    guard oldIndex == nextOld else { return false }
                    nextOld += 1
                case .insert(let newIndex):
                    guard newIndex == nextNew else { return false }
                    nextNew += 1
            }
        }
        return nextOld == old && nextNew == new
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    private static func editCount(_ edits: [DiffEdit]) -> Int {
        edits.filter { if case .equal = $0 { false } else { true } }.count
    }
}

/// A token source that records what it is asked for and returns nothing, so the words stand in.
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
private final class RecordingTokens: IntralineTokenSource {
    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    struct Request: Equatable {
        let isOld: Bool
        let lines: [Int]
    }

    private let recorded = Mutex<[Request]>([])

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    var requests: [Request] { recorded.withLock { $0 } }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    func tokenRanges(onOldSide: Bool, lineIndices: [Int]) -> [Int: [Range<Int>]] {
        recorded.withLock { $0.append(Request(isOld: onOldSide, lines: lineIndices)) }
        return [:]
    }
}

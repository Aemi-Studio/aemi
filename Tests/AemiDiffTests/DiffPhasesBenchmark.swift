import AemiDiff
import AemiText
import Foundation
import Testing

/// Opt-in timing of the diff's phases on the inputs perf-core measured, through APIs that stay across P1b, so a build
/// before it and a build after it run the same code and print comparable lines, in process CPU time: `AEMI_DIFF_BENCH=1 AEMI_DIFF_BENCH_REPO=<Atelier clone>
/// swift test -c release --filter DiffPhasesBenchmark`. Each line carries a checksum of what the phase produced, so
/// two builds that print the same checksum produce the same result.
///
/// - `lines`: both sides of a 50k-line pair split into lines (D3).
/// - `structure` and `histogram`: the line diff with the default pipeline and with rare lines anchored (D4, D8).
/// - `model word`: the whole `DiffModel` of that pair at the word granularity.
/// - `model long lines`: 2,000 lines of 600 bytes, one in ten edited, at the character granularity (D5).
/// - `intraline dissimilar`: 20 pairs of unrelated 2,000-unit lines at the character granularity (D5).
/// - `pairing wide lines`: a block of 60 removed and 60 added lines of 4 KB (Core S13).
/// - `moved repeated`: 5,000 removed and 5,000 added one-line runs of the same line (D6).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["AEMI_DIFF_BENCH"] != nil))
struct DiffPhasesBenchmark {
    private static let rounds = Int(ProcessInfo.processInfo.environment["AEMI_DIFF_BENCH_ROUNDS"] ?? "") ?? 11

    /// The revision the corpus is read at: the tree the first run of this benchmark read, before P1b's files joined it.
    private static let corpusRevision = "18a0cb6bdd0d2326b0e0be727178e89e2154b6a4"

    /// This package's Swift sources at ``corpusRevision``, joined, cut to `count` lines.
    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    private static func corpus(lines count: Int) throws -> [String] {
        let repository = try LineDiffBenchmark.atelier()
        let sources = try LineDiffBenchmark.swiftSources(at: corpusRevision, in: repository)
            .filter { $0.path.hasPrefix("Packages/AtelierCore/Sources/") }
        var lines: [String] = []
        for source in sources where lines.count < count {
            lines += source.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        }
        return Array(lines.prefix(count))
    }

    /// A 50k-line pair of this package's sources: one line in 97 changed, one in 331 dropped, a line added every 499.
    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    private static func scatteredPair() throws -> (old: String, new: String) {
        let base = try corpus(lines: 50_000)
        var edited: [String] = []
        for (index, line) in base.enumerated() {
            if index % 331 == 0 { continue }
            edited.append(index % 97 == 0 ? line + " // edited \(index)" : line)
            if index % 499 == 0 { edited.append("let inserted\(index) = \(index)") }
        }
        return (base.joined(separator: "\n") + "\n", edited.joined(separator: "\n") + "\n")
    }

    /// The phases through their own APIs (P1b), with the budgets of review §7.4: the structure within half the line
    /// diff's 200 ms deadline, one screen of emphasis within a frame, every change's within the 250 ms an L file has,
    /// and the moved lines within a frame.
    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `the phased APIs on a 50k pair`() async throws {
        let (oldText, newText) = try Self.scatteredPair()
        let old = TextLines(oldText)
        let new = TextLines(newText)
        let pipeline = DiffPipeline()
        var structure = try await LineDiff.structure(old: old, new: new, pipeline: pipeline)
        let structureCPU = try await Self.measureAsync("phased structure") {
            structure = try await LineDiff.structure(old: old, new: new, pipeline: pipeline)
            return structure.edits.count
        }
        var pairs: [[LinePair]] = []
        let pairsCPU = Self.measure("phased pairs, every change") {
            pairs = structure.changes.map {
                IntralineEmphasis.pairs(of: $0, old: old, new: new, pairing: pipeline.pairing)
            }
            return pairs.count
        }
        let screen = Array(structure.changes.indices.prefix(10))
        let screenCPU = try await Self.measureAsync("phased emphasis, one screen of 10 changes") {
            try await IntralineEmphasis.emphasis(
                for: screen, in: structure, pairs: pairs, old: old, new: new, granularity: .word,
                refiners: pipeline.intralineRefiners
            )
            .count
        }
        let everyCPU = try await Self.measureAsync("phased emphasis, every change") {
            try await IntralineEmphasis.emphasis(
                for: Array(structure.changes.indices), in: structure, pairs: pairs, old: old, new: new,
                granularity: .word, refiners: pipeline.intralineRefiners
            )
            .count
        }
        let movedCPU = Self.measure("phased moved lines") {
            MovedBlocks.detect(in: structure).new.filter { $0 }.count
        }
        #expect(structureCPU <= 100)
        #expect(pairsCPU <= 100)
        #expect(screenCPU <= 16)
        #expect(everyCPU <= 250)
        #expect(movedCPU <= 16)
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `the diff's phases`() throws {
        let (oldText, newText) = try Self.scatteredPair()
        let oldLines = DiffModel.lines(of: oldText)
        let newLines = DiffModel.lines(of: newText)

        Self.measure("lines 50k pair") { DiffModel.lines(of: oldText).count + DiffModel.lines(of: newText).count }
        Self.measure("structure 50k pair") { Self.checksum(LineDiff.diffLines(oldLines, newLines)) }
        Self.measure("histogram 50k pair") {
            Self.checksum(
                LineDiff.diffLines(
                    oldLines, newLines, pipeline: DiffPipeline(heuristics: DiffHeuristics(anchorsRareLines: true))))
        }
        Self.measure("model word 50k pair") {
            Self.checksum(
                DiffModel(oldText: oldText, newText: newText, granularity: .word, tokenRanges: CodeTokenRanges()))
        }

        var random = UInt64(0x5EED)
        func next() -> UInt64 {
            random = random &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return random >> 33
        }
        func line(_ length: Int) -> String {
            String((0 ..< length).map { _ in Character(UnicodeScalar(UInt8(97 + next() % 26))) })
        }
        let long = (0 ..< 2_000).map { _ in line(600) }
        let longEdited = long.enumerated()
            .map { index, text in
                index % 10 == 0 ? "x" + text.dropFirst(3) + "yz" : text
            }
        let longOld = long.joined(separator: "\n")
        let longNew = longEdited.joined(separator: "\n")
        Self.measure("model long lines") {
            Self.checksum(
                DiffModel(oldText: longOld, newText: longNew, granularity: .character, tokenRanges: CodeTokenRanges()))
        }
        let dissimilar = (0 ..< 20).map { _ in (Substring(line(2_000)), Substring(line(2_000))) }
        Self.measure("intraline dissimilar") {
            dissimilar.reduce(0) { sum, pair in
                sum + (IntralineDiff.emphasis(old: pair.0, new: pair.1, granularity: .character)?.old.count ?? -1)
            }
        }
        let wideRemoved = (0 ..< 60).map { _ in Substring(line(4_096)) }
        let wideAdded = wideRemoved.map { Substring("q" + $0.dropFirst()) }
        Self.measure("pairing wide lines") {
            SimilarityPairing().pairs(removed: wideRemoved, added: wideAdded)
                .reduce(0) { $0 &* 31 &+ ($1.old ?? -1) &* 7 &+ ($1.new ?? -1) }
        }
        let runs = (0 ..< 5_000).map { (index: $0 * 2, id: 0) }
        Self.measure("moved repeated") {
            let moved = MovedBlocks.detect(removed: runs, added: runs)
            return moved.old.count + moved.new.count
        }
    }

    /// ``measure(_:_:)`` for async work.
    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @discardableResult
    private static func measureAsync(_ name: String, _ work: () async throws -> Int) async throws -> Double {
        var samples: [Double] = []
        var checksum = 0
        for round in 0 ... rounds {
            let start = cpu()
            let result = try await work()
            let elapsed = cpu() - start
            if round == 0 { checksum = result } else { samples.append(elapsed) }
        }
        return report(name, samples, checksum: checksum)
    }

    /// Times `work` over the rounds, the first one a warm-up, and prints the median with its checksum.
    /// - Returns: The median, in milliseconds of CPU time.
    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @discardableResult
    private static func measure(_ name: String, _ work: () -> Int) -> Double {
        var samples: [Double] = []
        var checksum = 0
        for round in 0 ... rounds {
            let start = cpu()
            let result = work()
            let elapsed = cpu() - start
            if round == 0 { checksum = result } else { samples.append(elapsed) }
        }
        return report(name, samples, checksum: checksum)
    }

    /// Prints the median of `samples` with p10, p90 and the checksum, and returns the median.
    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    private static func report(_ name: String, _ samples: [Double], checksum: Int) -> Double {
        let sorted = samples.sorted()
        let pick = { (fraction: Double) in sorted[Int((Double(sorted.count - 1) * fraction).rounded())] }
        print(
            String(
                format: "BENCH diff-phases %@: median %.3f ms CPU (p10 %.3f, p90 %.3f), checksum %ld", name, pick(0.5),
                pick(0.1), pick(0.9), checksum))
        return pick(0.5)
    }

    /// The process's CPU time, in milliseconds: the suite runs alone, so it is the benchmark's.
    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    private static func cpu() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)) / 1e6
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    private static func checksum(_ edits: [DiffEdit]) -> Int {
        edits.reduce(edits.count) { hash, edit in
            switch edit {
                case .equal(let old, let new): hash &* 31 &+ old &* 3 &+ new
                case .delete(let old): hash &* 31 &+ old &* 5 &+ 1
                case .insert(let new): hash &* 31 &+ new &* 7 &+ 2
            }
        }
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    private static func checksum(_ model: DiffModel) -> Int {
        var hash = model.unifiedRows.count &* 31 &+ model.splitRows.count
        for row in model.splitRows + model.unifiedRows {
            hash = hash &* 31 &+ (row.old?.index ?? -1) &* 3 &+ (row.new?.index ?? -1) &+ (row.isMoved ? 7 : 0)
            for range in (row.old?.emphasis ?? []) + (row.new?.emphasis ?? []) {
                hash = hash &* 31 &+ range.lowerBound &* 5 &+ range.upperBound
            }
        }
        return hash
    }
}

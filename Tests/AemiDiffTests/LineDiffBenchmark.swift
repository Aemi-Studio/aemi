import Foundation
import Testing

@testable import AemiDiff

/// Opt-in timing of the line diff on the three pairs perf-core measured: about 50k lines of real history with about
/// 5k changed lines, a 50k-line rewrite in the same language, and 50k lines against 50k others. The first two come
/// from this repository's Swift sources at pinned revisions, so runs compare. Release numbers are the ones that mean
/// something: `AEMI_DIFF_BENCH=1 AEMI_DIFF_BENCH_REPO=<Atelier clone> swift test -c release -Xswiftc -enable-testing --filter LineDiffBenchmark`, with
/// `AEMI_DIFF_BENCH_ROUNDS` for the number of rounds and `AEMI_DIFF_BENCH_REPO` for the Atelier clone to read the revisions from.
struct LineDiffBenchmark {
    private static let olderRevision = "07ffec0668a2712518ee478d4cbaf6788079f281"
    private static let newerRevision = "e3b0d3e4ac5c3705bc449f1b206e14c13b949b72"
    private static let pairLines = 50_000

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AEMI_DIFF_BENCH"] != nil))
    func `myers on real history, on a rewrite and on disjoint lines`() throws {
        let repository = try Self.atelier()
        let older = Dictionary(
            try Self.swiftSources(at: Self.olderRevision, in: repository).map { ($0.path, $0.text) },
            uniquingKeysWith: { first, _ in first })
        let newer = try Self.swiftSources(at: Self.newerRevision, in: repository)

        // The files both revisions hold, in path order, until the newer side reaches the pair size.
        var historyOld: [Substring] = []
        var historyNew: [Substring] = []
        for (path, text) in newer where historyNew.count < Self.pairLines {
            guard let before = older[path] else { continue }
            historyNew += DiffModel.lines(of: text)
            historyOld += DiffModel.lines(of: before)
        }
        // The newer corpus cut in two: different files in the same language, sharing braces and blank lines.
        let corpus = newer.flatMap { DiffModel.lines(of: $0.text) }
        let rewriteOld = Array(corpus.prefix(Self.pairLines))
        let rewriteNew = Array(corpus.dropFirst(Self.pairLines).prefix(Self.pairLines))
        let disjointOld = (0 ..< Self.pairLines).map { Substring("let old\($0) = \($0)") }
        let disjointNew = (0 ..< Self.pairLines).map { Substring("let new\($0) = \($0)") }

        let rounds = Int(ProcessInfo.processInfo.environment["AEMI_DIFF_BENCH_ROUNDS"] ?? "") ?? 11
        let pairs: [(name: String, old: [Substring], new: [Substring])] = [
            ("real history", historyOld, historyNew), ("rewrite", rewriteOld, rewriteNew),
            ("disjoint", disjointOld, disjointNew)
        ]
        for (name, old, new) in pairs {
            var identifiers: [Substring: Int] = [:]
            let intern = { (line: Substring) -> Int in
                if let identifier = identifiers[line] { return identifier }
                identifiers[line] = identifiers.count
                return identifiers.count - 1
            }
            let oldIdentifiers = old.map(intern)
            let newIdentifiers = new.map(intern)
            // Through the line differ the default pipeline uses, specialized for interned lines in its module.
            let differ = MyersLineDiff()
            var edits: [DiffEdit] = []
            let samples = Self.samples(rounds) { edits = differ.diff(oldIdentifiers, newIdentifiers) }
            let cost = edits.count { if case .equal = $0 { false } else { true } }
            print(
                """
                BENCH myers \(name), \(old.count) against \(new.count) lines: D \(cost), \
                median \(samples.median), fastest \(samples.fastest) over \(rounds) rounds
                """)
        }
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    private static func samples(_ rounds: Int, _ body: () -> Void) -> (median: Duration, fastest: Duration) {
        let clock = ContinuousClock()
        let durations = (0 ..< max(rounds, 1)).map { _ in clock.measure(body) }.sorted()
        return (durations[durations.count / 2], durations[0])
    }

    /// The Atelier clone `AEMI_DIFF_BENCH_REPO` names, whose history the corpus is read from: the code moved here from
    /// Atelier, and its measurements were taken on that repository's revisions.
    static func atelier() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["AEMI_DIFF_BENCH_REPO"] else {
            throw CocoaError(
                .fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "set AEMI_DIFF_BENCH_REPO to an Atelier clone"])
        }
        return URL(filePath: path, directoryHint: .isDirectory)
    }

    /// Every Swift file under `Apps/` and `Packages/` at `revision`, by path, read through one `git cat-file --batch`.
    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    static func swiftSources(at revision: String, in repository: URL) throws -> [(path: String, text: String)] {
        let listing = try git(["ls-tree", "-r", "--name-only", revision], in: repository)
        let paths = String(decoding: listing, as: UTF8.self).split(separator: "\n").map(String.init)
            .filter { $0.hasSuffix(".swift") && ($0.hasPrefix("Apps/") || $0.hasPrefix("Packages/")) }.sorted()
        // Through a file: a request written to a pipe could fill it while git waits for its own output to be read.
        let request = FileManager.default.temporaryDirectory.appending(path: "line-diff-bench-\(UUID().uuidString)")
        try Data(paths.map { "\(revision):\($0)\n" }.joined().utf8).write(to: request)
        defer { try? FileManager.default.removeItem(at: request) }
        let batch = try git(["cat-file", "--batch"], in: repository, input: request)
        var texts: [(path: String, text: String)] = []
        var cursor = batch.startIndex
        for path in paths {
            guard let headerEnd = batch[cursor...].firstIndex(of: UInt8(ascii: "\n")) else { break }
            let header = String(decoding: batch[cursor ..< headerEnd], as: UTF8.self).split(separator: " ")
            guard header.count == 3, let size = Int(header[2]) else { break }
            let start = headerEnd + 1
            texts.append((path, String(decoding: batch[start ..< start + size], as: UTF8.self)))
            cursor = start + size + 1
        }
        return texts
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    static func git(_ arguments: [String], in repository: URL, input: URL? = nil) throws -> Data {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = ["-C", repository.path(percentEncoded: false)] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardInput = try input.map { try FileHandle(forReadingFrom: $0) } ?? FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data
    }
}

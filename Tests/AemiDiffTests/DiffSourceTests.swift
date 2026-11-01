import AemiTestKit
import Foundation
import Testing

@testable import AemiDiff

/// The byte-level line source against the substring path it replaces: same edit scripts, same indents, whatever
/// the whitespace mode, so a rope or a mapped file can be diffed without making strings.
struct DiffSourceTests {
    /// The interning the substring path used, kept as the oracle.
    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    private static func oracle(_ old: [Substring], _ new: [Substring], pipeline: DiffPipeline) -> [DiffEdit] {
        var identifiers: [Substring: Int] = [:]
        func intern(_ lines: [Substring]) -> [Int] {
            lines.map { line in
                let key = pipeline.whitespace.normalized(line)
                if let identifier = identifiers[key] { return identifier }
                let identifier = identifiers.count
                identifiers[key] = identifier
                return identifier
            }
        }
        let context = LineDiffContext(
            old: intern(old), new: intern(new), oldIndents: old.map(LineDiff.indent(of:)),
            newIndents: new.map(LineDiff.indent(of:)))
        var edits = pipeline.lineDiff.diff(context.old, context.new)
        for refiner in pipeline.refiners {
            edits = refiner.refine(edits, lines: context)
        }
        return edits
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    private static var modes: [WhitespaceMode] { [.exact, .ignoreTrailing, .ignoreLeadingAndTrailing, .ignoreAll] }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    private static var old: [Substring] {
        DiffModel.lines(
            of: "let a = 1\n  let b = 2  \n\tlet c = 3\r\nlet d = 4\n\nlet e = 5\nlet   f = 6\né = ✓\nlet a = 1\n")
    }
    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    private static var new: [Substring] {
        DiffModel.lines(
            of: "let a = 1\nlet b = 2\n    let c = 3\nlet d = 4\nlet e = 5\n\nlet f = 6\né = ✓\nlet g = 7\nlet a = 1\n")
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test(arguments: modes)
    func `substring lines give the oracle's edit script in every whitespace mode`(mode: WhitespaceMode) {
        let pipeline = DiffPipeline(whitespace: mode)
        let edits = LineDiff.diffLines(old: SubstringLines(Self.old), new: SubstringLines(Self.new), pipeline: pipeline)
        #expect(edits == Self.oracle(Self.old, Self.new, pipeline: pipeline))
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test(arguments: modes)
    func `byte lines give the same edit script as substring lines`(mode: WhitespaceMode) {
        let pipeline = DiffPipeline(whitespace: mode)
        let bytes = ByteLines(Self.old.map { Array($0.utf8) })
        let newBytes = ByteLines(Self.new.map { Array($0.utf8) })
        let edits = LineDiff.diffLines(old: bytes, new: newBytes, pipeline: pipeline)
        #expect(edits == Self.oracle(Self.old, Self.new, pipeline: pipeline))
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `the substring entry point is the byte path`() {
        let pipeline = DiffPipeline(whitespace: .ignoreAll)
        #expect(
            LineDiff.diffLines(Self.old, Self.new, pipeline: pipeline)
                == Self.oracle(Self.old, Self.new, pipeline: pipeline))
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `indents are measured on the bytes the same way`() {
        let lines = DiffModel.lines(of: "a\n  b\n\tc\n \t d\n\n\r\n  \t\n")
        let source = SubstringLines(lines)
        #expect((0 ..< source.lineCount).map { source.indent(at: $0) } == lines.map(LineDiff.indent(of:)))
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `two lines that only differ in bytes the mode ignores share one identity and nothing else does`() {
        let lines: [Substring] = ["a b", "a  b", "ab", "a b ", " a b", "ac"]
        for (mode, expectedDistinct) in [
            (WhitespaceMode.exact, 6), (.ignoreTrailing, 5), (.ignoreLeadingAndTrailing, 4), (.ignoreAll, 2)
        ] {
            var interner = LineInterner(whitespace: mode)
            let identifiers = interner.intern(SubstringLines(lines)).identifiers
            #expect(Set(identifiers).count == expectedDistinct, "\(mode)")
        }
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `random line sets agree with the oracle in every mode`() {
        var rng = SeededRNG(seed: 0x5EED_D1FF)
        let alphabet: [Substring] = ["", " ", "x", "x ", " x", "x y", "x  y", "\ty", "y", "z z", "  z", "é"]
        for _ in 0 ..< 200 {
            let oldCount = rng.int(in: 0 ... 12)
            let newCount = rng.int(in: 0 ... 12)
            let old = (0 ..< oldCount).map { _ in rng.pick(alphabet) }
            let new = (0 ..< newCount).map { _ in rng.pick(alphabet) }
            for mode in Self.modes {
                let pipeline = DiffPipeline(whitespace: mode)
                let expected = Self.oracle(old, new, pipeline: pipeline)
                #expect(
                    LineDiff.diffLines(old: SubstringLines(old), new: SubstringLines(new), pipeline: pipeline)
                        == expected)
                let bytes = LineDiff.diffLines(
                    old: ByteLines(old.map { Array($0.utf8) }), new: ByteLines(new.map { Array($0.utf8) }),
                    pipeline: pipeline)
                #expect(bytes == expected)
            }
        }
    }

    /// Opt-in timing of the interning paths on a large synthetic file; run with ATELIER_BENCH=1.
    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ATELIER_BENCH"] != nil))
    func `interning bytes is no slower than interning substrings`() {
        var rng = SeededRNG(seed: 42)
        // A 20,000-line file and a copy with a few hundred edited, inserted and removed lines: the shape a review
        // diff has, not two unrelated files, which would make the shortest edit script itself the cost measured.
        let oldLines = (0 ..< 20_000).map { "    let value\($0) = compute(\(rng.int(in: 0 ... 99)), with: options)" }
        var newLines = oldLines
        for _ in 0 ..< 500 {
            let at = rng.int(in: 0 ... newLines.count - 1)
            switch rng.int(in: 0 ... 2) {
                case 0: newLines[at] += "  // changed"
                case 1: newLines.insert("    inserted(\(at))", at: at)
                default: newLines.remove(at: at)
            }
        }
        let oldText = oldLines.joined(separator: "\n")
        let newText = newLines.joined(separator: "\n")
        let old = DiffModel.lines(of: oldText)
        let new = DiffModel.lines(of: newText)
        let pipeline = DiffPipeline(whitespace: .ignoreTrailing)
        let clock = ContinuousClock()
        var start = clock.now
        let expected = Self.oracle(old, new, pipeline: pipeline)
        let oracle = clock.now - start
        start = clock.now
        let edits = LineDiff.diffLines(old: SubstringLines(old), new: SubstringLines(new), pipeline: pipeline)
        let bytes = clock.now - start
        #expect(edits == expected)
        print("BENCH intern+diff 20k lines: substring dictionary \(oracle), byte hashing \(bytes)")
    }
}

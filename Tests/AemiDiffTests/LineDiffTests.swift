import Testing

@testable import AemiDiff

struct LineDiffTests {
    /// Typed up front: an untyped literal of tuples this long is more than the Swift 6.4 type checker
    /// resolves inside its budget, and the `@Test` macro expansion then fails to compile.
    private static let editScriptCases: [(old: [Int], new: [Int])] = [
        ([Int](), [Int]()),
        ([1, 2, 3], [1, 2, 3]),
        ([1, 2, 3], []),
        ([], [1, 2, 3]),
        ([1, 2, 3, 4], [1, 3, 4]),
        ([1, 3, 4], [1, 2, 3, 4]),
        ([1, 2, 3], [4, 5, 6]),
        ([1, 2, 3, 4, 5], [5, 4, 3, 2, 1]),
        ([1, 2, 2, 2, 3], [1, 2, 3]),
        ([3, 1, 2], [1, 2, 3]),
        ([1, 1, 1, 1], [1, 1]),
        (Array(1 ... 200), Array(1 ... 200).filter { $0 % 7 != 0 } + [999, 1000])
    ]

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test(arguments: editScriptCases)
    func `applying the edit script to old reproduces new`(old: [Int], new: [Int]) {
        let edits = LineDiff.diff(old, new)

        var rebuilt: [Int] = []
        var oldCursor = 0
        var newCursor = 0
        for edit in edits {
            switch edit {
                case .equal(let oldIndex, let newIndex):
                    #expect(oldIndex == oldCursor)
                    #expect(newIndex == newCursor)
                    #expect(old[oldIndex] == new[newIndex])
                    rebuilt.append(old[oldIndex])
                    oldCursor += 1
                    newCursor += 1
                case .delete(let oldIndex):
                    #expect(oldIndex == oldCursor)
                    oldCursor += 1
                case .insert(let newIndex):
                    #expect(newIndex == newCursor)
                    rebuilt.append(new[newIndex])
                    newCursor += 1
            }
        }
        #expect(oldCursor == old.count)
        #expect(newCursor == new.count)
        #expect(rebuilt == new)
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `edit script is minimal for a single inserted line`() {
        let edits = LineDiff.diff(["a", "b", "c"], ["a", "x", "b", "c"])
        #expect(edits == [.equal(old: 0, new: 0), .insert(new: 1), .equal(old: 1, new: 2), .equal(old: 2, new: 3)])
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `the shortest edit script prefers the common subsequence over rewriting everything`() {
        let edits = LineDiff.diff(
            ["a", "b", "c", "a", "b", "b", "a"],
            ["c", "b", "a", "b", "a", "c"],
            anchoringRareLines: false
        )
        let equalCount = edits.filter { if case .equal = $0 { true } else { false } }.count
        #expect(equalCount == 4)
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `line diff ignores carriage returns and a trailing newline`() {
        let model = DiffModel(oldText: "a\r\nb\r\n", newText: "a\nb\nc", tokenRanges: CodeTokenRanges())
        let oldLines: [Substring] = ["a", "b"]
        let newLines: [Substring] = ["a", "b", "c"]
        let kinds: [RowKind] = [.context, .context, .added]
        let unifiedKinds: [RowKind] = model.unifiedRows.map { (row: DiffRow) -> RowKind in row.kind }
        let splitKinds: [RowKind] = model.splitRows.map { (row: DiffRow) -> RowKind in row.kind }
        let changeStarts: [Int] = [2]
        #expect(model.oldLines == oldLines)
        #expect(model.newLines == newLines)
        #expect(unifiedKinds == kinds)
        #expect(splitKinds == kinds)
        #expect(model.unifiedChangeStarts == changeStarts)
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `split rows pair changed lines and pad the shorter side`() {
        let model = DiffModel(
            oldText: "one\ntwo\nthree",
            newText: "one\ntwo!\nthree\nfour\nfive",
            tokenRanges: CodeTokenRanges()
        )
        #expect(model.splitRows.map(\.kind) == [.context, .modified, .context, .added, .added])
        #expect(model.splitRows[1].old?.emphasis == [])
        #expect(model.splitRows[1].new?.emphasis == [3 ..< 4])
        #expect(model.splitRows[3].old == nil)
        #expect(model.unifiedRows.map(\.kind) == [.context, .removed, .added, .context, .added, .added])
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `intraline emphasis is dropped when most of the line changed`() {
        #expect(IntralineDiff.emphasis(old: "let value = 1", new: "print(\"hello\")") == nil)
        let emphasis = IntralineDiff.emphasis(old: "let value = 1", new: "let value = 12")
        #expect(emphasis?.old == [])
        #expect(emphasis?.new == [13 ..< 14])
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `anchoring on rare lines keeps a moved function together instead of matching braces across it`() {
        let old: [Substring] = ["func a() {", "    one", "}", "", "func b() {", "    two", "}"]
        let new: [Substring] = ["func b() {", "    two", "}", "", "func a() {", "    one", "}"]
        var heuristics = DiffHeuristics.none
        heuristics.anchorsRareLines = true

        let anchored = LineDiff.diffLines(old, new, pipeline: DiffPipeline(heuristics: heuristics))
        let plain = LineDiff.diffLines(old, new, pipeline: DiffPipeline(heuristics: .none))

        func changes(_ edits: [DiffEdit]) -> [DiffEdit] { edits.filter { if case .equal = $0 { false } else { true } } }
        // Both keep one function unchanged, but only anchoring keeps that function's lines in one run.
        #expect(changes(anchored).count == changes(plain).count)
        let anchoredEquals = anchored.compactMap { if case .equal(let old, _) = $0 { old } else { nil } }
        #expect(anchoredEquals == [4, 5, 6] || anchoredEquals == [3, 4, 5, 6] || anchoredEquals == [0, 1, 2, 3])
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `the indent heuristic starts an inserted function on its declaration rather than on the closing brace above`()
    {
        let old: [Substring] = ["func a() {", "    one", "}", ""]
        let new: [Substring] = ["func a() {", "    one", "}", "", "func b() {", "    two", "}", ""]
        var heuristics = DiffHeuristics.none
        heuristics.slidesToIndentation = true

        let slid = LineDiff.diffLines(old, new, pipeline: DiffPipeline(heuristics: heuristics))
        let plain = LineDiff.diffLines(old, new, pipeline: DiffPipeline(heuristics: .none))

        let inserted = slid.compactMap { if case .insert(let new) = $0 { new } else { nil } }
        #expect(inserted == [4, 5, 6, 7])
        #expect(plain.count == slid.count)
    }

    @Test(arguments: [
        (WhitespaceMode.exact, false),
        (.ignoreTrailing, false),
        (.ignoreLeadingAndTrailing, true),
        (.ignoreAll, true)
    ])
    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    func `whitespace modes decide whether a re-indented line changed`(mode: WhitespaceMode, isSame: Bool) {
        var heuristics = DiffHeuristics.none
        heuristics.whitespace = mode
        let edits = LineDiff.diffLines(
            ["  let a = 1"],
            ["    let a = 1"],
            pipeline: DiffPipeline(heuristics: heuristics)
        )
        #expect(edits.allSatisfy { if case .equal = $0 { true } else { false } } == isSame)
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `similar lines pair across an inserted line and leftovers still zip by position`() {
        let pairs = SimilarityPairing()
            .pairs(
                removed: ["let total = price * quantity", "return total"],
                added: ["let subtotal = price * quantity", "let total = subtotal + tax", "return total"]
            )
        #expect(pairs == [LinePair(old: 0, new: 0), LinePair(old: nil, new: 1), LinePair(old: 1, new: 2)])

        let unrelated = SimilarityPairing().pairs(removed: ["b"], added: ["x"])
        #expect(unrelated == [LinePair(old: 0, new: 0)])
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `semantic cleanup folds coincidental common letters into the replacement`() {
        let raw = IntralineDiff.emphasis(old: "foo(bar)", new: "boo(baz)", granularity: .character)
        let cleaned = IntralineDiff.emphasis(
            old: "foo(bar)",
            new: "boo(baz)",
            granularity: .character,
            refiners: [SemanticCleanup()]
        )
        #expect(raw?.old.count == 2)
        #expect(cleaned?.old == [0 ..< 1, 6 ..< 7])
        #expect(cleaned?.new == [0 ..< 1, 6 ..< 7])

        let word = IntralineDiff.emphasis(
            old: "self.count = items.count",
            new: "self.total = items.total",
            granularity: .word,
            refiners: [SemanticCleanup()]
        )
        #expect(word?.old == [5 ..< 10, 19 ..< 24])

        let reindented = IntralineDiff.emphasis(old: "    let a = 1", new: "        let a = 2", granularity: .word)
        #expect(reindented?.old == [12 ..< 13])
        #expect(reindented?.new == [16 ..< 17])
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `blocks that only moved are flagged on both sides`() {
        let old = "one\ntwo\nthree\nalpha\nbeta\ngamma\ndelta\n"
        let new = "alpha\nbeta\ngamma\ndelta\none\ntwo\nthree\n"
        let model = DiffModel(oldText: old, newText: new, tokenRanges: CodeTokenRanges())

        let movedOld = model.unifiedRows.filter { $0.isMoved && $0.kind == .removed }.compactMap { $0.old?.index }
        let movedNew = model.unifiedRows.filter { $0.isMoved && $0.kind == .added }.compactMap { $0.new?.index }
        #expect(movedOld == [0, 1, 2])
        #expect(movedNew == [4, 5, 6])

        let off = DiffModel(
            oldText: old,
            newText: new,
            pipeline: DiffPipeline(heuristics: .none),
            tokenRanges: CodeTokenRanges()
        )
        #expect(off.unifiedRows.allSatisfy { !$0.isMoved })
    }
}

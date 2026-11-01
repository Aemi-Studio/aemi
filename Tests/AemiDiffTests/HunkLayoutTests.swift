import Testing

@testable import AemiDiff

struct HunkLayoutTests {
    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `each change gets context rows around it and hunks that touch are merged`() {
        let hunks = HunkLayout.hunks(changeRanges: [5 ..< 6, 9 ..< 10, 40 ..< 42], rowCount: 100, context: 3)
        #expect(hunks == [2 ..< 13, 37 ..< 45])
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `hunks are clipped to the document`() {
        #expect(
            HunkLayout.hunks(changeRanges: [0 ..< 2, 98 ..< 100], rowCount: 100, context: 3) == [0 ..< 5, 95 ..< 100]
        )
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `no changes means no hunks`() {
        #expect(HunkLayout.hunks(changeRanges: [], rowCount: 50, context: 3) == [])
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `expanding a gap reveals rows below the previous hunk and above the next one`() {
        let hunks = HunkLayout.hunks(
            changeRanges: [10 ..< 11, 50 ..< 51],
            rowCount: 100,
            context: 2,
            expansions: [
                1: GapExpansion(below: 5, above: 4), 0: GapExpansion(below: 0, above: 3),
                2: GapExpansion(below: 10, above: 0)
            ]
        )
        #expect(hunks == [5 ..< 18, 44 ..< 63])
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `an expansion that closes a gap merges the hunks`() {
        let hunks = HunkLayout.hunks(
            changeRanges: [10 ..< 11, 20 ..< 21],
            rowCount: 100,
            context: 2,
            expansions: [1: GapExpansion(below: 100, above: 0)]
        )
        #expect(hunks == [8 ..< 23])
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `the diff model exposes change ranges for both layouts`() {
        let model = DiffModel(oldText: "a\nb\nc\nd\n", newText: "a\nB\nc\nd\ne\n", tokenRanges: CodeTokenRanges())
        #expect(model.unifiedChangeRanges == [1 ..< 3, 5 ..< 6])
        #expect(model.splitChangeRanges == [1 ..< 2, 4 ..< 5])
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `gap keys follow the base hunks even after an expansion merges two of them`() {
        let ranges = [5 ..< 6, 12 ..< 13, 30 ..< 31]
        let plain = HunkLayout.layout(changeRanges: ranges, rowCount: 60, context: 1)
        #expect(plain.hunks.map(\.rows) == [4 ..< 7, 11 ..< 14, 29 ..< 32])
        #expect(plain.baseCount == 3)

        let merged = HunkLayout.layout(
            changeRanges: ranges,
            rowCount: 60,
            context: 1,
            expansions: [1: GapExpansion(below: 100)]
        )
        #expect(merged.hunks.map(\.rows) == [4 ..< 14, 29 ..< 32])
        #expect(merged.hunks.map(\.firstBase) == [0, 2])
        #expect(merged.baseCount == 3)

        let trailing = HunkLayout.layout(
            changeRanges: ranges,
            rowCount: 60,
            context: 1,
            expansions: [1: GapExpansion(below: 100), 3: GapExpansion(below: 10)]
        )
        #expect(trailing.hunks.last?.rows == 29 ..< 42)
    }
}

import Testing

@testable import AemiDiff

/// Gutter marks from an edit script: what an editor shows beside a buffer that differs from its committed base.
struct LineChangeMarkersTests {
    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    private static func markers(_ old: String, _ new: String) -> [Int: LineChange] {
        LineChangeMarkers(old: SubstringLines(DiffModel.lines(of: old)), new: SubstringLines(DiffModel.lines(of: new)))
            .byLine
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `identical sides carry no marks and an empty new side carries none either`() {
        #expect(Self.markers("a\nb\n", "a\nb\n").isEmpty)
        #expect(Self.markers("a\nb\n", "").isEmpty)
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `a changed line is modified, an extra line is added, and a removed line marks the line below it`() {
        #expect(Self.markers("a\nb\nc\n", "a\nB\nc\n") == [1: .modified])
        #expect(Self.markers("a\nc\n", "a\nb\nc\n") == [1: .added])
        #expect(Self.markers("a\nb\nc\n", "a\nc\n") == [1: .deleted])
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `removed and inserted lines of one change pair up in order and the surplus keeps its own mark`() {
        // Two removed, three inserted: two modified, one added.
        #expect(Self.markers("a\nx\ny\nz\n", "a\n1\n2\n3\nz\n") == [1: .modified, 2: .modified, 3: .added])
        // Three removed, one inserted: one modified, then a deletion mark on the line after it.
        #expect(Self.markers("a\nx\ny\nz\nb\n", "a\n1\nb\n") == [1: .modified, 2: .deleted])
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `a removal at the very end marks the last line and a deletion outranks a modification`() {
        #expect(Self.markers("a\nb\nc\n", "a\nb\n") == [1: .deleted])
        // The line after the removal is itself modified; the deletion wins.
        #expect(Self.markers("a\nx\ny\nz\n", "a\nY\n") == [1: .deleted])
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `marks come straight from an edit script too`() {
        let edits: [DiffEdit] = [
            .equal(old: 0, new: 0), .delete(old: 1), .insert(new: 1), .insert(new: 2), .equal(old: 2, new: 3),
            .delete(old: 3)
        ]
        let markers = LineChangeMarkers(edits: edits, newLineCount: 4)
        #expect(markers.byLine == [1: .modified, 2: .added, 3: .deleted])
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `modified pairs are the removed and inserted lines of one run, matched in order`() {
        let edits: [DiffEdit] = [
            .equal(old: 0, new: 0), .delete(old: 1), .delete(old: 2), .insert(new: 1), .equal(old: 3, new: 2),
            .insert(new: 3), .delete(old: 4), .insert(new: 4), .insert(new: 5)
        ]
        let pairs = LineChangeMarkers.modifiedPairs(edits: edits)
        #expect(pairs.map { [$0.old, $0.new] } == [[1, 1], [4, 3]])
        let marks = LineChangeMarkers(edits: edits, newLineCount: 6).byLine
        #expect(pairs.allSatisfy { marks[$0.new] == .modified })
        #expect(LineChangeMarkers.modifiedPairs(edits: [.equal(old: 0, new: 0)]).isEmpty)
    }
}

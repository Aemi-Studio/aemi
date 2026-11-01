import Testing

@testable import AemiDiff

/// The line-break contract of `DiffModel.lines(of:)`: only a line feed ends a line, so a lone carriage return is
/// content, and a carriage return directly before the line feed belongs to the break, not to the line. This is the
/// same rule as git, `TextLines` and `LineSourceTests`; `DiffRenderer.lineRanges(of:lines:)` relies on this cut, as
/// it walks the lines it is given, rather than splitting on its own. So the diff, the gutter and the hunk numbers
/// count the same lines. Splitting at a lone carriage return here alone would break that agreement, so it has to
/// change in all of them together.
@Suite
struct DiffModelLineBreakTests {
    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    private static func lines(of text: String) -> [String] {
        DiffModel.lines(of: text).map(String.init)
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `a lone carriage return inside an unterminated line stays in it`() {
        #expect(Self.lines(of: "a\rb") == ["a\rb"])
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `a trailing carriage return at the end of the text is dropped`() {
        #expect(Self.lines(of: "a\r") == ["a"])
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `only the carriage return directly before the line feed is dropped`() {
        #expect(Self.lines(of: "a\r\r\n") == ["a\r"])
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `a lone carriage return inside a line stays in it`() {
        #expect(Self.lines(of: "a\rb\nc\n") == ["a\rb", "c"])
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `a carriage return and line feed together are one break and the carriage return is not in the line`() {
        #expect(Self.lines(of: "a\r\nb\r\n") == ["a", "b"])
    }
}

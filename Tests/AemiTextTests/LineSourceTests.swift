import Testing

@testable import AemiText

/// A string's lines as the diff cuts them, lent through `LineSource`.
struct LineSourceTests {
    /// Every line of `source`, read through `withLineBytes`, as a string.
    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    private static func lines(of source: some LineSource) -> [String] {
        (0 ..< source.lineCount)
            .map { index in
                source.withLineBytes(at: index) { bytes in
                    bytes.withUnsafeBufferPointer { String(decoding: $0, as: UTF8.self) }
                }
            }
    }

    /// The diff's own cut (`DiffModel.lines(of:)`), restated: split at `\n`, drop each line's final `\r`, drop the
    /// empty tail after a final line break, and no line for a text of one empty line.
    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    private static func diffLines(_ text: String) -> [String] {
        var lines = text.utf8.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
            .map { line in String(decoding: line.last == UInt8(ascii: "\r") ? line.dropLast() : line, as: UTF8.self) }
        if lines.count > 1, lines[lines.count - 1].isEmpty { lines.removeLast() }
        if lines.count == 1, lines[0].isEmpty { return [] }
        return lines
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test(arguments: ["", "\n", "\r\n", "\r", "a", "a\n", "a\r\nb", "a\n\nb\n", "\n\n", "é✓\r\n🙂\r\n", "x\r", "a\rb\n"])
    func `a string's lines are the diff's lines`(text: String) {
        let lines = TextLines(text)

        #expect(Self.lines(of: lines) == Self.diffLines(text))
        #expect(lines.lineCount == Self.diffLines(text).count)
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `a string's line ranges lie in its bytes, without the line breaks`() {
        let lines = TextLines("ab\r\ncd\n\nef")

        #expect(lines.lineRanges == [0 ..< 2, 4 ..< 6, 7 ..< 7, 8 ..< 10])
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `generated strings cut into the diff's lines`() {
        let pieces = ["a", "é", "🙂", " ", "\n", "\r\n", "\r"]
        var state: UInt64 = 0x51
        for _ in 0 ..< 300 {
            var text = ""
            for _ in 0 ..< 30 {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                text += pieces[Int(state >> 33) % pieces.count]
            }
            #expect(Self.lines(of: TextLines(text)) == Self.diffLines(text), "\(text.debugDescription)")
        }
    }
}

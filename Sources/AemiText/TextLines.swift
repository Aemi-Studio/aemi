internal import AemiKernels

/// A string's lines as a diff cuts them (`DiffModel.lines(of:)`), each lent in place from the string's UTF-8: split at
/// each `\n`, with a line's trailing `\r` left out so a CRLF text's lines equal an LF text's, the empty tail after a
/// final line break ignored, and no line at all for an empty text or a text of one empty line.
///
/// It holds the string and where each line starts, found with ``AemiKernels/firstIndexOfByte(base:count:needle:backend:)``
/// (libc's vectorised `memchr`), so reading a line costs O(1) and nothing is copied.
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
public struct TextLines: LineSource {
    public let text: String
    /// Where each line starts in `text`'s UTF-8, then one past where the last line's terminator is or would be: line
    /// `i` ends at `starts[i + 1] - 1`, less a `\r` just before that.
    private let starts: [Int]

    /// Splits `text` into its lines.
    /// - Complexity: O(bytes of `text`), one byte search per line.
    public init(_ text: String) {
        var text = text
        text.makeContiguousUTF8()
        starts = Self.lineStarts(of: text)
        self.text = text
    }

    /// Where each line of `text` starts, then the end marker ``starts`` describes.
    private static func lineStarts(of text: String) -> [Int] {
        let utf8 = text.utf8Span
        let bytes = utf8.span
        var starts = [0]
        starts.reserveCapacity(bytes.count / 32 + 2)
        bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let found =
                    offset
                    + AemiKernels.firstIndexOfByte(base: base + offset, count: buffer.count - offset, needle: 0x0A)
                guard found < buffer.count else { break }
                offset = found + 1
                starts.append(offset)
            }
        }
        // The piece after the last line break is a line too, until it is found blank below.
        starts.append(bytes.count + 1)
        // A last line left empty once its `\r` is dropped is no line, as the diff counts it: a final line break ends
        // the one before it. Then a text of one empty line has none.
        let lastStart = starts[starts.count - 2]
        let lastEnd = starts[starts.count - 1] - 1
        var lastIsBlank = lastEnd == lastStart
        if lastEnd == lastStart + 1, bytes[lastStart] == 0x0D { lastIsBlank = true }
        guard lastIsBlank else { return starts }
        guard starts.count > 2 else { return [0] }
        starts.removeLast()
        if starts.count == 2 {
            let end = starts[1] - 1
            if end == 0 { return [0] }
            if end == 1, bytes[0] == 0x0D { return [0] }
        }
        return starts
    }

    public var lineCount: Int { starts.count - 1 }

    /// Line `index`'s UTF-8 bytes in ``text``, without its line break or the `\r` before one.
    /// - Precondition: `index` is in `0 ..< lineCount`.
    public func byteRange(ofLine index: Int) -> Range<Int> {
        let start = starts[index]
        var end = starts[index + 1] - 1
        if end > start {
            let utf8 = text.utf8Span
            if utf8.span[end - 1] == 0x0D { end -= 1 }
        }
        return start ..< end
    }

    /// Every line's ``byteRange(ofLine:)``, in order.
    public var lineRanges: [Range<Int>] {
        (0 ..< lineCount).map(byteRange(ofLine:))
    }

    public func withLineBytes<R, E: Error>(at index: Int, _ body: (Span<UInt8>) throws(E) -> R) throws(E) -> R {
        let range = byteRange(ofLine: index)
        let utf8 = text.utf8Span
        return try body(utf8.span.extracting(range))
    }
}

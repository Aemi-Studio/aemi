internal import AemiKernels

/// Where each line of a byte buffer starts, so a byte offset becomes a line and a column only when someone asks (ADR 0031):
/// parsers carry offsets, and a diagnostic is the only reader of positions. The line breaks are found in one pass by the bulk
/// positions kernel (`adf_positions_of_either`: NEON, AVX2, SSE2), not by a search per line; a lookup is a binary search.
///
/// Promoted from AemiHMMML's `LineIndex`: TOML ends lines at LF and CRLF, YAML also at a lone CR.
public struct LineIndex: Sendable, Hashable {
    /// Which bytes end a line.
    public enum Breaks: Sendable, Hashable {
        /// LF and CRLF (TOML; a lone CR ends no line).
        case lineFeed
        /// LF, CRLF and a lone CR (YAML 1.2.2's `b-break`).
        case lineFeedOrReturn
    }

    /// A byte offset with the line and column a person reads, all 1-based.
    public struct Location: Sendable, Hashable, CustomStringConvertible {
        public let offset: Int
        public let line: Int
        /// Unicode scalars from the line's start, plus one: what an editor shows for well-formed UTF-8.
        public let column: Int
        /// Bytes from the line's start, plus one.
        public let byteColumn: Int

        public init(offset: Int, line: Int, column: Int, byteColumn: Int) {
            self.offset = offset
            self.line = line
            self.column = column
            self.byteColumn = byteColumn
        }

        public var description: String { "\(line):\(column)" }
    }

    private let bytes: [UInt8]
    /// The offset of each line's first byte; the first is 0.
    private let starts: [UInt32]

    /// The lines of `bytes`, which must be shorter than 4 GiB.
    public init(_ bytes: [UInt8], breaks: Breaks) {
        self.bytes = bytes
        var found: [UInt32] = []
        found.reserveCapacity(bytes.count / 32 + 1)
        AemiKernels.appendPositions(ofEither: 0x0A, breaks == .lineFeed ? 0x0A : 0x0D, in: bytes, into: &found)
        var starts: [UInt32] = [0]
        starts.reserveCapacity(found.count + 1)
        for position in found {
            let at = Int(position)
            // A CR followed by an LF ends its line at the LF.
            if bytes[at] == 0x0D, at + 1 < bytes.count, bytes[at + 1] == 0x0A { continue }
            starts.append(position + 1)
        }
        self.starts = starts
    }

    /// Lines in the buffer; one that ends with a break has an empty last line.
    public var lineCount: Int { starts.count }

    /// The offset of line `line`'s first byte (0-based `line`).
    public func start(ofLine line: Int) -> Int { Int(starts[line]) }

    /// The line and column of `offset`, clamped into the buffer (`0 ... count`).
    public func location(of offset: Int) -> Location {
        let offset = Swift.min(Swift.max(0, offset), bytes.count)
        var low = 0
        var high = starts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if Int(starts[middle]) <= offset { low = middle } else { high = middle - 1 }
        }
        let start = Int(starts[low])
        var scalars = 0
        for byte in bytes[start ..< offset] where byte & 0xC0 != 0x80 { scalars += 1 }
        return Location(offset: offset, line: low + 1, column: scalars + 1, byteColumn: offset - start + 1)
    }
}

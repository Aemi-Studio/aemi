import AemiKernel
public import AemiText

/// Lines a diff runs over: a text kit's substrings, bytes, a rope or a string's ``TextLines``. A source lends its lines
/// by index, so nothing is diffed through a string of its own: identity comes from hashing the normalised bytes and
/// equal hashes are confirmed byte by byte (review §7.4: the diff and the lexers share one line source).
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
public typealias DiffSource = LineSource

@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
extension LineSource {
    /// Leading whitespace width of line `index`, tabs to the next multiple of eight; nil for a blank line.
    public func indent(at index: Int) -> Int? {
        withLineBytes(at: index) { LineDiff.indent(of: $0) }
    }
}

/// Lines held as substrings of one string, as the text kit side of a diff produces them.
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
public struct SubstringLines: DiffSource {
    public let lines: [Substring]

    public init(_ lines: [Substring]) {
        self.lines = lines
    }

    public var lineCount: Int { lines.count }

    public func withLineBytes<R, E: Error>(at index: Int, _ body: (Span<UInt8>) throws(E) -> R) throws(E) -> R {
        let line = lines[index]
        var lent: Result<R, E>?
        _ = line.utf8.withContiguousStorageIfAvailable { buffer in
            lent = Result { () throws(E) -> R in try body(unsafe Span(_unsafeElements: buffer)) }
        }
        if let lent { return try lent.get() }
        // A non-contiguous substring, which native strings never are: copy this one line.
        let bytes = Array(line.utf8)
        return try body(bytes.span)
    }
}

/// Lines held as byte arrays, one per line, without terminators.
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
public struct ByteLines: DiffSource {
    public let lines: [[UInt8]]

    public init(_ lines: [[UInt8]]) {
        self.lines = lines
    }

    public var lineCount: Int { lines.count }

    public func withLineBytes<R, E: Error>(at index: Int, _ body: (Span<UInt8>) throws(E) -> R) throws(E) -> R {
        let line = lines[index]
        return try body(line.span)
    }
}

/// Gives every distinct line one small integer, across both sides of a diff, under a whitespace mode.
///
/// Identity is the XXH64 of the normalised bytes, seeded per interner so no crafted input can line its hashes up
/// (Aemi #31). The hashes index one flat open-addressed table (perf-core D4), and the normalised bytes of every
/// distinct line are kept in one arena, so a hash already seen is confirmed by one comparison against the arena: a
/// collision can only cost that comparison, never a wrong match. Identifiers are dense, in first-seen order.
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
struct LineInterner {
    let whitespace: WhitespaceMode
    private let seed: UInt64
    /// One more than the identifier each slot holds; 0 for an empty slot. Always a power of two long, at most half
    /// full.
    private var slots: [Int] = Array(repeating: 0, count: 16)
    /// The hash of each identifier's normalised bytes.
    private var hashes: [UInt64] = []
    /// The normalised bytes of every identifier, back to back, and where each one lies.
    private var arena: [UInt8] = []
    private var ranges: [Range<Int>] = []

    init(whitespace: WhitespaceMode, seed: UInt64 = .random(in: .min ... .max)) {
        self.whitespace = whitespace
        self.seed = seed
    }

    /// One identifier per line of `source`, and each line's indent measured in the same pass; a later source's
    /// lines match an earlier source's.
    /// - Complexity: O(bytes of the source), plus one comparison per repeated line.
    mutating func intern(_ source: some LineSource) -> (identifiers: [Int], indents: [Int?]) {
        var identifiers: [Int] = []
        var indents: [Int?] = []
        identifiers.reserveCapacity(source.lineCount)
        indents.reserveCapacity(source.lineCount)
        reserve(ranges.count + source.lineCount)
        var scratch: [UInt8] = []
        for line in 0 ..< source.lineCount {
            let (identifier, indent) = source.withLineBytes(at: line) { bytes in
                (
                    whitespace.withNormalized(bytes, scratch: &scratch) { normalized in identify(normalized) },
                    LineDiff.indent(of: bytes)
                )
            }
            identifiers.append(identifier)
            indents.append(indent)
        }
        return (identifiers, indents)
    }

    /// The identifier of `normalized`, registering it when it is new.
    private mutating func identify(_ normalized: UnsafeRawBufferPointer) -> Int {
        let hash = XXH64.hash(normalized, seed: seed)
        let mask = slots.count - 1
        var slot = Int(truncatingIfNeeded: hash) & mask
        while slots[slot] != 0 {
            let identifier = slots[slot] - 1
            if hashes[identifier] == hash, matches(identifier, normalized) { return identifier }
            slot = (slot + 1) & mask
        }
        let identifier = ranges.count
        let start = arena.count
        arena.append(contentsOf: normalized)
        ranges.append(start ..< arena.count)
        hashes.append(hash)
        slots[slot] = identifier + 1
        if 2 * ranges.count > slots.count { reserve(ranges.count) }
        return identifier
    }

    /// Grows the table, when needed, so `count` identifiers keep it at most half full.
    private mutating func reserve(_ count: Int) {
        var capacity = slots.count
        while capacity < 2 * count { capacity *= 2 }
        guard capacity > slots.count else { return }
        slots = Array(repeating: 0, count: capacity)
        let mask = capacity - 1
        for identifier in hashes.indices {
            var slot = Int(truncatingIfNeeded: hashes[identifier]) & mask
            while slots[slot] != 0 { slot = (slot + 1) & mask }
            slots[slot] = identifier + 1
        }
    }

    private func matches(_ identifier: Int, _ normalized: UnsafeRawBufferPointer) -> Bool {
        let range = ranges[identifier]
        guard range.count == normalized.count else { return false }
        return arena.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress, let other = normalized.baseAddress else { return range.isEmpty }
            return ByteCompare.equal(
                base.assumingMemoryBound(to: UInt8.self) + range.lowerBound, other.assumingMemoryBound(to: UInt8.self),
                range.count)
        }
    }
}

@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
extension WhitespaceMode {
    /// Calls `body` with the bytes of `line` that take part in comparison under this mode: a sub-range of the
    /// line for the trimming modes, a filtered copy in `scratch` when inner whitespace is ignored.
    /// - Complexity: O(line)
    func withNormalized<R>(_ line: Span<UInt8>, scratch: inout [UInt8], _ body: (UnsafeRawBufferPointer) -> R) -> R {
        var start = 0
        var end = line.count
        switch self {
            case .exact:
                break
            case .ignoreTrailing:
                while end > 0, Self.isSpace(line[end - 1]) { end -= 1 }
            case .ignoreLeadingAndTrailing:
                while start < end, Self.isSpace(line[start]) { start += 1 }
                while end > start, Self.isSpace(line[end - 1]) { end -= 1 }
            case .ignoreAll:
                scratch.removeAll(keepingCapacity: true)
                scratch.reserveCapacity(line.count)
                for index in 0 ..< line.count where !Self.isSpace(line[index]) {
                    scratch.append(line[index])
                }
                return scratch.withUnsafeBytes(body)
        }
        return line.withUnsafeBufferPointer { buffer in
            body(UnsafeRawBufferPointer(UnsafeBufferPointer(rebasing: buffer[start ..< end])))
        }
    }
}

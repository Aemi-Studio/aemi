internal import AemiKernels

/// XML / SVG text escaping over UTF-8: replaces the five XML 1.0 predefined-entity metacharacters —
/// `&`, `<`, `>`, `"`, `'` — with `&amp;`, `&lt;`, `&gt;`, `&quot;`, `&apos;`, and copies every other
/// byte verbatim. The metacharacters are all ASCII, so escaping at the byte level never splits a
/// multi-byte scalar. One canonical escaper for the family's hand-built XML/SVG output (OpenSearch
/// descriptors, glyph and symbol SVGs), replacing the per-site `replacingOccurrences` / `+=` copies.
/// Domain-neutral and `Foundation`-free; one result allocation, no recursion, no trap.
///
/// `&apos;` (the XML 1.0 predefined entity) is used for the apostrophe rather than the HTML-style
/// numeric `&#39;`, so the output is valid in any XML/SVG context and byte-compatible with the
/// hand-rolled escapers it consolidates. The conservative five-character set covers both element text
/// and double-quoted attribute values: escaping `"`/`'` inside element text is harmless, and escaping
/// `&`/`<`/`>` everywhere is required.
public enum XMLEscape {
    /// Escape `value` for XML/SVG text or a double-quoted attribute value, returning the escaped bytes.
    @inlinable
    public static func escape(_ value: String) -> [UInt8] {
        var copy = value
        return copy.withUTF8 { unsafe escapeBytes($0) }
    }

    /// Escapes a contiguous UTF-8 buffer: a runtime-dispatched SIMD scan (`firstIndexOfAny`) jumps to
    /// the next metacharacter, each safe run is bulk-copied, and the entity is emitted at the stop —
    /// replacing the per-byte append. Non-metacharacter bytes (incl. multi-byte UTF-8) copy verbatim.
    @usableFromInline
    static func escapeBytes(_ buffer: UnsafeBufferPointer<UInt8>) -> [UInt8] {
        guard let base = buffer.baseAddress else { return [] }
        let count = buffer.count
        var out: [UInt8] = []
        out.reserveCapacity(count)
        var index = 0
        while index < count {
            let run = unsafe AemiKernels.firstIndexOfAny(
                base: base + index, count: count - index, 0x26, 0x3C, 0x3E, 0x22, 0x27)
            if run > 0 {
                unsafe out.append(contentsOf: UnsafeBufferPointer(start: base + index, count: run))
                index += run
            }
            guard index < count else { break }
            switch unsafe buffer[index] {
                case 0x26: out.append(contentsOf: "&amp;".utf8)  // &
                case 0x3C: out.append(contentsOf: "&lt;".utf8)  // <
                case 0x3E: out.append(contentsOf: "&gt;".utf8)  // >
                case 0x22: out.append(contentsOf: "&quot;".utf8)  // "
                default: out.append(contentsOf: "&apos;".utf8)  // ' (0x27; the only remaining stop)
            }
            index += 1
        }
        return out
    }

    /// `String` convenience over ``escape(_:)`` for the XML/SVG builders that assemble a `String`.
    @inlinable
    public static func escaped(_ value: String) -> String {
        String(decoding: escape(value), as: UTF8.self)
    }
}

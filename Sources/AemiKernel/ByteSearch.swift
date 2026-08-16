/// In-house byte-needle search + split over a `[UInt8]` buffer — the primitive that
/// `multipart/form-data` boundary scanning and similar wire-format parsing need (MultipartKit is
/// `vapor/*`, excluded by the dependency rule). Pure standard library, no unsafe pointers (so it is
/// `StrictMemorySafety`-clean). Relocated from ADServe's `MultipartParser` so any AD-family parser
/// can share one scanner instead of re-rolling it; semantics are byte-identical to that original.
public enum ByteSearch {
    /// The first range of `needle` within `haystack`, expressed in `haystack`'s OWN indices (an
    /// `ArraySlice` keeps its parent array's indices, not 0-based ones), or `nil` when `needle` is
    /// empty, longer than `haystack`, or absent. A plain forward scan — no skip table — matching the
    /// extracted original; do not "optimize" it without a benchmark proving a real parser hot path.
    public static func firstRange(of needle: [UInt8], in haystack: ArraySlice<UInt8>) -> Range<Int>? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        let lastStart = haystack.endIndex - needle.count
        var index = haystack.startIndex
        while index <= lastStart {
            if haystack[index] == needle[0] {
                var matched = true
                for offset in 1 ..< needle.count where haystack[index + offset] != needle[offset] {
                    matched = false
                    break
                }
                if matched { return index ..< (index + needle.count) }
            }
            index += 1
        }
        return nil
    }

    /// Split `bytes` on every non-overlapping occurrence of `separator`, returning the slices
    /// between separators (the separators themselves removed). An empty or absent `separator`
    /// yields the whole input as a single slice; adjacent separators yield empty slices.
    public static func split(_ bytes: [UInt8], on separator: [UInt8]) -> [ArraySlice<UInt8>] {
        guard !separator.isEmpty else { return [bytes[...]] }
        var result: [ArraySlice<UInt8>] = []
        var start = bytes.startIndex
        while let range = firstRange(of: separator, in: bytes[start...]) {
            result.append(bytes[start ..< range.lowerBound])
            start = range.upperBound
        }
        result.append(bytes[start...])
        return result
    }
}

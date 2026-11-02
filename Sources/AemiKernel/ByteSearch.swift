internal import AemiKernels

/// In-house byte-needle search + split over a `[UInt8]` buffer — the primitive that
/// `multipart/form-data` boundary scanning and similar wire-format parsing need (MultipartKit is
/// `vapor/*`, excluded by the dependency rule). Relocated from ADServe's `MultipartParser` so any
/// AD-family parser can share one scanner instead of re-rolling it; its answers are those of that
/// original. The search runs on the SIMD kernel of `AemiKernels` (NEON, AVX2, SSE2) and is linear
/// in the worst case whatever the input: a crafted one falls back to Knuth-Morris-Pratt.
public enum ByteSearch {
    /// The first range of `needle` within `haystack`, expressed in `haystack`'s OWN indices (an
    /// `ArraySlice` keeps its parent array's indices, not 0-based ones), or `nil` when `needle` is
    /// empty, longer than `haystack`, or absent.
    ///
    /// - Complexity: O(`haystack.count` + `needle.count`) for every input (ADR 0026).
    public static func firstRange(of needle: [UInt8], in haystack: ArraySlice<UInt8>) -> Range<Int>? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        let found = haystack.withUnsafeBufferPointer { hay in
            needle.withUnsafeBufferPointer { pattern in unsafe AemiKernels.firstIndex(of: pattern, in: hay) }
        }
        guard let found else { return nil }
        let start = haystack.startIndex + found
        return start ..< (start + needle.count)
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

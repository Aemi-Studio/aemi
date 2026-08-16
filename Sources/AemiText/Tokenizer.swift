// Domain-neutral tokenizer kernels: fixed-size sliding windows (n-grams) and predicate splitting.
// Both yield `[Range<C.Index>]` rather than copied subsequences, so the caller chooses the element
// granularity (bytes, scalars, characters) and slices on demand with no intermediate allocation —
// the same value-in/index-out philosophy as the edit-distance kernels. Iterative; no recursion.
// Grammar-specific tokenizers (SQLite unicode61/trigram, BERT/transformers.js) stay in their owning
// packages and build on these.

extension AemiText {
    /// Fixed-size sliding windows over `collection` as index ranges — the n-gram primitive behind
    /// trigram-style indexing. Returns `count - size + 1` consecutive `size`-wide ranges, or an empty
    /// array when `size <= 0` or `size` exceeds the element count (no partial trailing window).
    public static func windows<C: Collection>(_ collection: C, size: Int) -> [Range<C.Index>] {
        guard size > 0 else { return [] }
        guard
            var windowEnd = collection.index(
                collection.startIndex, offsetBy: size, limitedBy: collection.endIndex)
        else { return [] }  // size exceeds the element count
        var start = collection.startIndex
        var result: [Range<C.Index>] = []
        while true {
            result.append(start ..< windowEnd)
            if windowEnd == collection.endIndex { break }
            start = collection.index(after: start)
            windowEnd = collection.index(after: windowEnd)
        }
        return result
    }

    /// Splits `collection` into the maximal runs of non-separator elements, as index ranges. Mirrors
    /// `Sequence.split`: with `omittingEmptySubsequences` (the default) adjacent separators and
    /// leading/trailing separators produce no empty token; pass `false` to keep them.
    public static func split<C: Collection>(
        _ collection: C, omittingEmptySubsequences: Bool = true,
        where isSeparator: (C.Element) -> Bool
    ) -> [Range<C.Index>] {
        var result: [Range<C.Index>] = []
        var tokenStart = collection.startIndex
        var index = collection.startIndex
        while index != collection.endIndex {
            if isSeparator(collection[index]) {
                if !omittingEmptySubsequences || tokenStart != index {
                    result.append(tokenStart ..< index)
                }
                tokenStart = collection.index(after: index)
            }
            index = collection.index(after: index)
        }
        if !omittingEmptySubsequences || tokenStart != index {
            result.append(tokenStart ..< index)
        }
        return result
    }
}

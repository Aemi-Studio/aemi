/// The highlighting tier that produced a token.
/// Higher layers take precedence when tokens overlap.
public enum HighlightLayer: UInt8, Sendable, Comparable, Hashable {
    /// The scanners (AemiLexers).
    case lexical = 0
    /// A tree-sitter grammar's highlights query.
    case structural = 1
    /// swift-syntax, the compiler's own parser: it outranks a tree-sitter grammar.
    case syntactic = 2
    /// A language server's semantic tokens, which refine every layer below.
    case semantic = 3

    public static func < (lhs: HighlightLayer, rhs: HighlightLayer) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

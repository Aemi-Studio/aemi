/// Modifiers that can be applied to a highlight token to convey additional semantics.
public struct HighlightModifierSet: OptionSet, Sendable, Hashable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let declaration = HighlightModifierSet(rawValue: 1 << 0)
    public static let definition = HighlightModifierSet(rawValue: 1 << 1)
    public static let readonly = HighlightModifierSet(rawValue: 1 << 2)
    public static let `static` = HighlightModifierSet(rawValue: 1 << 3)
    public static let deprecated = HighlightModifierSet(rawValue: 1 << 4)
    public static let async = HighlightModifierSet(rawValue: 1 << 5)
    public static let documentation = HighlightModifierSet(rawValue: 1 << 6)
    /// The symbol belongs to a default or standard library: LSP's `defaultLibrary`, sourcekit-lsp's signal that a
    /// name comes from outside the edited target, the only tier that can tell a project symbol from another one's.
    public static let defaultLibrary = HighlightModifierSet(rawValue: 1 << 7)
}

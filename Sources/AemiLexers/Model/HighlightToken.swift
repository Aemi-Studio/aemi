/// A highlighted region of source code that keeps its meaning (role, modifiers, layer) rather than a style, so the
/// tokens of several highlighting layers can be merged before any style is chosen. The scanners build it directly, in
/// the ``HighlightLayer/lexical`` layer: a client keeps their tokens as they come, with nothing to map.
public struct HighlightToken: Sendable, Equatable {
    public let byteRange: Range<Int>
    public let role: HighlightRole
    public let modifiers: HighlightModifierSet
    public let layer: HighlightLayer
    public let priority: Int

    public init(
        byteRange: Range<Int>,
        role: HighlightRole,
        modifiers: HighlightModifierSet = [],
        layer: HighlightLayer = .structural,
        priority: Int = 0
    ) {
        self.byteRange = byteRange
        self.role = role
        self.modifiers = modifiers
        self.layer = layer
        self.priority = priority
    }
}

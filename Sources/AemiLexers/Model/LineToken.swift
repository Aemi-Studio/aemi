/// One token of one line, in 12 bytes: where it starts from the line's start, its length, its role and its modifiers.
///
/// A line's tokens hold no layer and no priority: whoever cuts tokens into lines resolves their overlaps first, so a
/// line's tokens are ascending and disjoint.
/// The offsets are in the unit the tokens were cut in, UTF-8 bytes or UTF-16 units.
public struct LineToken: Sendable, Hashable {
    /// Where the token starts, from its line's start.
    public var start: UInt32
    public var length: UInt32
    public var role: HighlightRole
    public var modifiers: HighlightModifierSet

    /// A token over `range`, from its line's start. A bound past `UInt32.max` is clamped to it: no line that long is
    /// ever shown, and clamping keeps the token in its line rather than trapping.
    public init(range: Range<Int>, role: HighlightRole, modifiers: HighlightModifierSet = []) {
        let lower = UInt32(clamping: range.lowerBound)
        start = lower
        length = UInt32(clamping: range.upperBound) - lower
        self.role = role
        self.modifiers = modifiers
    }

    /// The token's offsets from its line's start.
    public var range: Range<Int> {
        Int(start) ..< Int(start) + Int(length)
    }
}

/// The `String` surface for string-backed identifiers.
///
/// `@dynamicMemberLookup` already forwards the raw value's *properties*
/// (`count`, `isEmpty`, `first`, `utf8`, …) because those are reachable by key
/// path. Methods are not, so the ones a string identifier actually needs are
/// forwarded here.
///
/// A `Collection` conformance is the obvious alternative and the wrong one. It
/// is a Character-level protocol: it would supply `starts(with:)`, `split`, and
/// `prefix`, but none of `hasPrefix`, `uppercased()`, `trimmingCharacters(in:)`,
/// `replacingOccurrences(of:with:)`, `range(of:)`, or `caseInsensitiveCompare`.
/// It would also let an identifier satisfy any `Sequence` parameter and make
/// `Array(id)` and `id.reduce(0, +)` compile. Forwarding gives the whole
/// surface and none of that.
///
/// Anything not forwarded here stays reachable as `id.rawValue`.

extension Identifier where RawValue: StringProtocol {
    @inlinable
    public func hasPrefix(_ prefix: some StringProtocol) -> Bool {
        rawValue.hasPrefix(prefix)
    }

    @inlinable
    public func hasSuffix(_ suffix: some StringProtocol) -> Bool {
        rawValue.hasSuffix(suffix)
    }

    @inlinable
    public func uppercased() -> String {
        rawValue.uppercased()
    }

    @inlinable
    public func lowercased() -> String {
        rawValue.lowercased()
    }

    /// Splits a composite identifier into its components.
    /// - Complexity: O(n) in the raw value's length.
    @inlinable
    public func split(
        separator: Character,
        maxSplits: Int = .max,
        omittingEmptySubsequences: Bool = true
    ) -> [RawValue.SubSequence] {
        rawValue.split(
            separator: separator,
            maxSplits: maxSplits,
            omittingEmptySubsequences: omittingEmptySubsequences
        )
    }

    /// - Note: clamps rather than traps when `maxLength` exceeds the length.
    @inlinable
    public func prefix(_ maxLength: Int) -> RawValue.SubSequence {
        rawValue.prefix(maxLength)
    }

    /// - Note: clamps rather than traps when `maxLength` exceeds the length.
    @inlinable
    public func suffix(_ maxLength: Int) -> RawValue.SubSequence {
        rawValue.suffix(maxLength)
    }
}

#if canImport(Foundation)
public import Foundation

extension Identifier where RawValue: StringProtocol {
    /// - Complexity: O(n) in the raw value's length.
    @inlinable
    public func trimmingCharacters(in set: CharacterSet) -> String {
        rawValue.trimmingCharacters(in: set)
    }

    /// - Complexity: O(n·m) for a raw value of length n and a target of length m.
    @inlinable
    public func replacingOccurrences(
        of target: some StringProtocol,
        with replacement: some StringProtocol
    ) -> String {
        rawValue.replacingOccurrences(of: target, with: replacement)
    }

    /// - Returns: the range of the first occurrence, or `nil` if absent.
    /// - Complexity: O(n·m) for a raw value of length n and a target of length m.
    @inlinable
    public func range(of target: some StringProtocol) -> Range<RawValue.Index>? {
        rawValue.range(of: target)
    }

    /// - Complexity: O(n·m) for a raw value of length n and a target of length m.
    @inlinable
    public func contains(_ target: some StringProtocol) -> Bool {
        rawValue.range(of: target) != nil
    }

    /// Compares without regard to case, and without regard to locale.
    ///
    /// - Note: the localized variants are deliberately not forwarded. An
    ///   identifier's ordering must not change with the user's locale.
    @inlinable
    public func caseInsensitiveCompare(_ other: some StringProtocol) -> ComparisonResult {
        rawValue.caseInsensitiveCompare(other)
    }
}
#endif

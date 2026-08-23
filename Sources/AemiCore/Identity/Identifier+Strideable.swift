/// The one part of Tagged's arithmetic tower that suits an identifier.
///
/// `Strideable` refines only `Comparable`, so it makes a run of sequential
/// identifiers countable without admitting arithmetic between two identifiers:
///
/// ```swift
/// for id in TicketID(1)..<TicketID(100) { … }        // countable range
/// stride(from: TicketID(0), to: TicketID(9), by: 3)  // stepped walk
/// let next = id + 1                                  // -> TicketID
/// let gap  = id2 - id1                               // -> Int, the stride
/// let bad  = id1 + id2                               // does not compile
/// ```
///
/// `AdditiveArithmetic` and `Numeric` would add `.zero` and `.magnitude` and
/// cost the guarantee on the last line, so they stay out.
extension Identifier: Strideable where RawValue: Strideable {
    /// - Complexity: the raw value's own, typically O(1).
    @inlinable
    public func distance(to other: Self) -> RawValue.Stride {
        rawValue.distance(to: other.rawValue)
    }

    /// - Complexity: the raw value's own, typically O(1).
    @inlinable
    public func advanced(by n: RawValue.Stride) -> Self {
        Self(rawValue: rawValue.advanced(by: n))
    }
}

// `Strideable` supplies default `==` and `<` that route through `Stride`, which
// would recurse forever if `Self` were its own `Stride`. It cannot be here:
// `Stride` is `RawValue.Stride`, and the concrete witnesses in
// Identifier+Hashable.swift take precedence regardless.

/// Offsetting operators, which the standard library declares per conforming
/// type rather than handing to every `Strideable`.
///
/// Only the stride-taking forms exist, so `id + 1` moves an identifier and
/// `id2 - id1` measures the gap, while `id1 + id2` stays a compile error. The
/// identifier's own `ExpressibleByIntegerLiteral` conformance does not capture
/// the literal here: the stride overload is the better match.
extension Identifier where RawValue: Strideable {
    /// - Precondition: the raw value's own; `Int` traps on overflow.
    @inlinable
    public static func + (lhs: Self, rhs: RawValue.Stride) -> Self {
        lhs.advanced(by: rhs)
    }

    /// - Precondition: the raw value's own; `Int` traps on overflow.
    @inlinable
    public static func + (lhs: RawValue.Stride, rhs: Self) -> Self {
        rhs.advanced(by: lhs)
    }

    /// - Precondition: the raw value's own; `Int` traps on overflow.
    @inlinable
    public static func - (lhs: Self, rhs: RawValue.Stride) -> Self {
        lhs.advanced(by: -rhs)
    }

    /// The gap between two identifiers, as a stride rather than an identifier.
    @inlinable
    public static func - (lhs: Self, rhs: Self) -> RawValue.Stride {
        rhs.distance(to: lhs)
    }

    @inlinable
    public static func += (lhs: inout Self, rhs: RawValue.Stride) {
        lhs = lhs.advanced(by: rhs)
    }

    @inlinable
    public static func -= (lhs: inout Self, rhs: RawValue.Stride) {
        lhs = lhs.advanced(by: -rhs)
    }
}

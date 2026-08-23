// An ID-specialized refinement of pointfreeco/swift-tagged's `Tagged`,
// informed by that repo's issue history. It ships inside AemiCore rather than
// a module of its own: a module named `Identifier` would collide with the type
// and break xcodebuild (tagged #80).
//
// Deliberately omitted, per tagged's own lessons and measurements of our own:
// ExpressibleByNilLiteral (optional-promotion ambiguity), the property wrapper
// (projects away the type safety), the arithmetic tower beyond `Strideable`
// (identifiers are not quantities), `Collection`/`Sequence` (a Character-level
// surface that does not carry the `String` API, while letting an identifier
// satisfy any sequence parameter), `Error` (an identifier is not a failure),
// and `LosslessStringConvertible` (see ``Identifier/parse(_:)``).

/// A phantom-typed identifier: `Identifier<Part, UUID>` and
/// `Identifier<Supplier, UUID>` are distinct, incompatible types even though
/// both wrap a `UUID`. Mixing them up is a compile error, not a runtime bug.
@dynamicMemberLookup
public struct Identifier<Owner, RawValue> {
    /// The untyped value as it appears on the wire.
    public var rawValue: RawValue

    @inlinable
    public init(rawValue: RawValue) {
        self.rawValue = rawValue
    }

    @inlinable
    public init(_ rawValue: RawValue) {
        self.rawValue = rawValue
    }

    /// Forwards the raw value's properties. A key path reaches stored and
    /// computed members; a method on the raw value needs an explicit forward,
    /// as in the `StringProtocol` extension.
    @inlinable
    public subscript<Subject>(dynamicMember keyPath: KeyPath<RawValue, Subject>) -> Subject {
        rawValue[keyPath: keyPath]
    }

    /// Transforms the raw value while keeping the owner.
    @inlinable
    public func map<NewValue>(
        _ transform: (RawValue) throws -> NewValue
    ) rethrows -> Identifier<Owner, NewValue> {
        Identifier<Owner, NewValue>(rawValue: try transform(rawValue))
    }

    /// Reinterprets this identifier as belonging to another owner.
    /// Named to signal semantic seriousness — use only at genuine domain
    /// boundaries (e.g. DTO ↔ domain model of the same entity).
    ///
    /// Invariant for the bitcast: `Owner` is phantom (never stored), so both
    /// specializations have the identical layout of a bare `RawValue`.
    @inlinable
    public func coerced<NewOwner>(to owner: NewOwner.Type) -> Identifier<NewOwner, RawValue> {
        unsafe unsafeBitCast(self, to: Identifier<NewOwner, RawValue>.self)
    }
}

// MARK: - Pass-through hook

/// Generic surface for "some `Identifier`", used by consumers (e.g.
/// `Snapshot`) to detect models that already carry a typed identifier and
/// expose it as-is instead of wrapping it again.
public protocol IdentifierProtocol: Hashable {
    associatedtype Owner
    associatedtype RawValue: Hashable
    var rawValue: RawValue { get }
}

extension Identifier: IdentifierProtocol where RawValue: Hashable {}

// MARK: - Core conformances

extension Identifier: RawRepresentable {}

extension Identifier: Sendable where RawValue: Sendable {}

#if compiler(>=6.0)
extension Identifier: BitwiseCopyable where RawValue: BitwiseCopyable {}
#endif

#if compiler(>=6.2)
extension Identifier: SendableMetatype where RawValue: SendableMetatype {}
#endif

/// An identifier is trivially its own identity — stronger than Tagged's
/// `where RawValue: Identifiable` forwarding, and what SwiftUI diffing wants.
extension Identifier: Identifiable where RawValue: Hashable {
    @inlinable
    public var id: Self { self }
}

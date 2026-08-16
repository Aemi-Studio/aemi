// An ID-specialized refinement of pointfreeco/swift-tagged's `Tagged`,
// informed by that repo's issue history. The module is named AppIdentity,
// not Identifier: module == type name breaks xcodebuild (tagged #80).
// Deliberately omitted, per tagged's own lessons: ExpressibleByNilLiteral
// (optional-promotion ambiguity), property wrapper (projects away the type
// safety), LosslessStringConvertible (init ambiguity), and the arithmetic
// tower — identifiers are not quantities.

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

extension Identifier: Equatable where RawValue: Equatable {}
extension Identifier: Hashable where RawValue: Hashable {}
extension Identifier: Sendable where RawValue: Sendable {}

#if compiler(>=6.0)
extension Identifier: BitwiseCopyable where RawValue: BitwiseCopyable {}
#endif

#if compiler(>=6.2)
extension Identifier: SendableMetatype where RawValue: SendableMetatype {}
#endif

extension Identifier: Comparable where RawValue: Comparable {
    @inlinable
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// An identifier is trivially its own identity — stronger than Tagged's
/// `where RawValue: Identifiable` forwarding, and what SwiftUI diffing wants.
extension Identifier: Identifiable where RawValue: Hashable {
    @inlinable
    public var id: Self { self }
}

// MARK: - Descriptions

extension Identifier: CustomStringConvertible {
    public var description: String {
        String(describing: rawValue)
    }
}

extension Identifier: CustomDebugStringConvertible {
    public var debugDescription: String {
        "Identifier<\(Owner.self)>(\(rawValue))"
    }
}

// MARK: - Codable

extension Identifier: Decodable where RawValue: Decodable {
    public init(from decoder: any Decoder) throws {
        // Container path handles Optional/null; the fallback respects
        // decoder strategies (dates, data). Neither alone is sufficient
        // (swift-tagged #24/#55).
        do {
            self.init(rawValue: try decoder.singleValueContainer().decode(RawValue.self))
        } catch {
            self.init(rawValue: try RawValue(from: decoder))
        }
    }
}

extension Identifier: Encodable where RawValue: Encodable {
    public func encode(to encoder: any Encoder) throws {
        do {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        } catch {
            try rawValue.encode(to: encoder)
        }
    }
}

// Without this, `[Identifier: V]` dictionaries encode as flat [key, value,
// key, value] arrays instead of keyed objects (swift-tagged issues #58/#65).
// No @available needed: the package's platform floors exceed SE-0320's.
extension Identifier: CodingKeyRepresentable where RawValue: CodingKeyRepresentable {
    public var codingKey: any CodingKey {
        rawValue.codingKey
    }

    public init?<T: CodingKey>(codingKey: T) {
        guard let rawValue = RawValue(codingKey: codingKey) else { return nil }
        self.init(rawValue: rawValue)
    }
}

// MARK: - Literal expressibility (fixture/test ergonomics)

extension Identifier: ExpressibleByIntegerLiteral where RawValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: RawValue.IntegerLiteralType) {
        self.init(rawValue: RawValue(integerLiteral: value))
    }
}

extension Identifier: ExpressibleByUnicodeScalarLiteral where RawValue: ExpressibleByUnicodeScalarLiteral {
    public init(unicodeScalarLiteral value: RawValue.UnicodeScalarLiteralType) {
        self.init(rawValue: RawValue(unicodeScalarLiteral: value))
    }
}

extension Identifier: ExpressibleByExtendedGraphemeClusterLiteral
where RawValue: ExpressibleByExtendedGraphemeClusterLiteral {
    public init(extendedGraphemeClusterLiteral value: RawValue.ExtendedGraphemeClusterLiteralType) {
        self.init(rawValue: RawValue(extendedGraphemeClusterLiteral: value))
    }
}

extension Identifier: ExpressibleByStringLiteral where RawValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: RawValue.StringLiteralType) {
        self.init(rawValue: RawValue(stringLiteral: value))
    }
}

extension Identifier: ExpressibleByStringInterpolation where RawValue: ExpressibleByStringInterpolation {
    public init(stringInterpolation: RawValue.StringInterpolation) {
        self.init(rawValue: RawValue(stringInterpolation: stringInterpolation))
    }
}

// MARK: - UUID conveniences (swift-tagged PR #63)

#if canImport(Foundation)
public import Foundation

extension Identifier where RawValue == UUID {
    public init() {
        self.init(rawValue: UUID())
    }

    public init?(uuidString: String) {
        guard let uuid = UUID(uuidString: uuidString) else { return nil }
        self.init(rawValue: uuid)
    }
}
#endif

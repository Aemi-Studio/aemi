/// An identifier key with the owner erased — for collections that mix
/// entities, e.g. `[AnyIdentifier<UUID>: Marker]` keyed by both part and
/// work-order ids.
///
/// `[any IdentifierProtocol: V]` cannot exist (an existential does not
/// conform to `Hashable`), and `AnyHashable` boxes and drops `Sendable`.
/// This type erases only the owner: the raw value stays typed, and the
/// owner's identity participates in equality and hashing, so two entities'
/// ids remain distinct keys even when their raw values collide.
public struct AnyIdentifier<RawValue: Hashable>: Hashable {
    public let owner: ObjectIdentifier
    public let rawValue: RawValue

    public init<ID: IdentifierProtocol>(_ id: ID) where ID.RawValue == RawValue {
        self.owner = ObjectIdentifier(ID.Owner.self)
        self.rawValue = id.rawValue
    }

    /// Whether this key was erased from an identifier of the given owner.
    public func belongs<Owner>(to owner: Owner.Type) -> Bool {
        self.owner == ObjectIdentifier(owner)
    }
}

extension AnyIdentifier: Sendable where RawValue: Sendable {}

extension Identifier where RawValue: Hashable {
    /// This identifier as a mixed-collection key; see ``AnyIdentifier``.
    @inlinable
    public var erased: AnyIdentifier<RawValue> {
        AnyIdentifier(self)
    }
}

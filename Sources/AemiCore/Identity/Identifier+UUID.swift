// UUID conveniences (swift-tagged PR #63).

#if canImport(Foundation)
public import Foundation

extension Identifier where RawValue == UUID {
    /// Generates a fresh identifier.
    @inlinable
    public init() {
        self.init(rawValue: UUID())
    }

    /// - Parameter uuidString: a UUID in its canonical form, such as
    ///   `DEADBEEF-DEAD-BEEF-DEAD-BEEFDEADBEEF`.
    /// - Returns: `nil` if the string is not a well-formed UUID.
    @inlinable
    public init?(uuidString: String) {
        guard let uuid = UUID(uuidString: uuidString) else { return nil }
        self.init(rawValue: uuid)
    }
}
#endif

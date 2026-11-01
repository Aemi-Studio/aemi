// UUID conveniences (swift-tagged PR #63).

#if canImport(Foundation)
    public import Foundation

    extension Identifier where RawValue == UUID {
        /// Generates a fresh identifier.
        @inlinable
        public init() {
            self.init(rawValue: UUID())
        }

        /// The identifier of `uuidString`, or `nil` if the string is not a well-formed UUID.
        ///
        /// - Parameter uuidString: a UUID in its canonical form, such as
        ///   `DEADBEEF-DEAD-BEEF-DEAD-BEEFDEADBEEF`.
        @inlinable
        public init?(uuidString: String) {
            guard let uuid = UUID(uuidString: uuidString) else { return nil }
            self.init(rawValue: uuid)
        }
    }
#endif

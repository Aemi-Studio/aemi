extension Identifier where RawValue: LosslessStringConvertible {
    /// Reads an identifier from the string form of its raw value.
    ///
    /// This is a named factory rather than a `LosslessStringConvertible`
    /// conformance. That conformance requires `init?(_ description: String)`,
    /// which outranks `init(_ rawValue: RawValue)` when `RawValue == String`:
    /// `Identifier<User, String>("abc")` would start returning
    /// `Identifier<User, String>?` and silently change every existing call
    /// site. A named factory has no such collision.
    ///
    /// - Parameter description: the raw value's string form.
    /// - Returns: the identifier, or `nil` if the raw value rejects the input.
    /// - Complexity: the raw value's own parsing cost.
    @inlinable
    public static func parse(_ description: String) -> Self? {
        guard let rawValue = RawValue(description) else { return nil }
        return Self(rawValue: rawValue)
    }
}

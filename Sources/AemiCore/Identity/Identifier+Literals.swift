/// Literal expressibility, for fixture and test ergonomics.
///
/// Boolean and floating-point literals are absent on purpose: a `Bool`-backed
/// identifier carries one bit of identity, and a `Double`-backed one puts
/// identity on a type whose equality is approximate.

extension Identifier: ExpressibleByIntegerLiteral where RawValue: ExpressibleByIntegerLiteral {
    @inlinable
    public init(integerLiteral value: RawValue.IntegerLiteralType) {
        self.init(rawValue: RawValue(integerLiteral: value))
    }
}

extension Identifier: ExpressibleByUnicodeScalarLiteral
where RawValue: ExpressibleByUnicodeScalarLiteral {
    @inlinable
    public init(unicodeScalarLiteral value: RawValue.UnicodeScalarLiteralType) {
        self.init(rawValue: RawValue(unicodeScalarLiteral: value))
    }
}

extension Identifier: ExpressibleByExtendedGraphemeClusterLiteral
where RawValue: ExpressibleByExtendedGraphemeClusterLiteral {
    @inlinable
    public init(extendedGraphemeClusterLiteral value: RawValue.ExtendedGraphemeClusterLiteralType) {
        self.init(rawValue: RawValue(extendedGraphemeClusterLiteral: value))
    }
}

extension Identifier: ExpressibleByStringLiteral where RawValue: ExpressibleByStringLiteral {
    @inlinable
    public init(stringLiteral value: RawValue.StringLiteralType) {
        self.init(rawValue: RawValue(stringLiteral: value))
    }
}

extension Identifier: ExpressibleByStringInterpolation
where RawValue: ExpressibleByStringInterpolation {
    @inlinable
    public init(stringInterpolation: RawValue.StringInterpolation) {
        self.init(rawValue: RawValue(stringInterpolation: stringInterpolation))
    }
}

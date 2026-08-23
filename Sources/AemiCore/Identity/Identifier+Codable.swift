/// An identifier codes as its bare raw value, so the wire format never shows
/// that a phantom type was involved.

extension Identifier: Decodable where RawValue: Decodable {
    /// - Throws: whatever the raw value's decoding throws.
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
    /// The single-value container already applies the encoder's strategies, so
    /// there is no encode-side counterpart to the decode fallback above.
    ///
    /// Retrying a failed encode against the same encoder would mask the first
    /// error behind a second and ask an encoder that already holds a container
    /// to hand out another.
    ///
    /// - Throws: whatever the raw value's encoding throws, unmodified.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
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

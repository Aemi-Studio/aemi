/// A colour as sRGB components, each 0 to 1 and gamma-encoded, as a `#rrggbb` says it. Out-of-range or non-finite
/// components are clamped (0 for NaN), so every value here is a colour.
public struct RGB: Sendable, Hashable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = Self.clamped(red)
        self.green = Self.clamped(green)
        self.blue = Self.clamped(blue)
    }

    /// The same grey in all three.
    public init(white: Double) {
        self.init(red: white, green: white, blue: white)
    }

    /// From 8-bit components, as `[r, g, b]`; nil unless there are exactly three.
    public init?(bytes: [UInt8]) {
        guard bytes.count == 3 else { return nil }
        self.init(red: Double(bytes[0]) / 255, green: Double(bytes[1]) / 255, blue: Double(bytes[2]) / 255)
    }

    /// From `#rrggbb`, `rrggbb`, `#rgb` or `rgb`; nil for anything else.
    public init?(hex: String) {
        var digits = Substring(hex)
        if digits.first == "#" { digits = digits.dropFirst() }
        guard digits.count == 3 || digits.count == 6, digits.allSatisfy(\.isHexDigit) else { return nil }
        let expanded = digits.count == 3 ? String(digits.flatMap { [$0, $0] }) : String(digits)
        guard let value = UInt32(expanded, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    public static let black = Self(white: 0)
    public static let white = Self(white: 1)

    private static func clamped(_ value: Double) -> Double {
        value.isNaN ? 0 : min(max(value, 0), 1)
    }
}

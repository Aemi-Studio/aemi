/// ASCII hexadecimal digit coding. Consolidates the three near-identical decoders that lived in
/// ADJSON (`JSONString.hexValue`, `JSONNumber.hexDigitValue`, the scanner's `hexValue`) plus the
/// `JSONOutput.hexDigit` encoder. Callers that want lenient or throwing `\uXXXX` decoding build
/// their policy on top of ``value(_:)``.
public enum Hex {
    /// Decodes one ASCII hex digit (`0-9`, `a-f`, `A-F`) to its 0–15 value, or `nil` otherwise.
    @inlinable
    public static func value(_ b: UInt8) -> UInt8? {
        switch b {
            case 0x30 ... 0x39: return b - 0x30
            case 0x61 ... 0x66: return b - 0x61 + 10
            case 0x41 ... 0x46: return b - 0x41 + 10
            default: return nil
        }
    }

    /// Encodes a nibble (0–15) to its lowercase ASCII hex digit. Input above 15 is a programmer error.
    @inlinable
    public static func digit(_ nibble: UInt8) -> UInt8 {
        nibble < 10 ? 0x30 + nibble : 0x61 + (nibble - 10)
    }

    /// Encodes a nibble (0–15) to its uppercase ASCII hex digit — the form RFC 3986 §2.1 recommends
    /// for percent-encoding. Input above 15 is a programmer error.
    @inlinable
    public static func upperDigit(_ nibble: UInt8) -> UInt8 {
        nibble < 10 ? 0x30 + nibble : 0x41 + (nibble - 10)
    }
}

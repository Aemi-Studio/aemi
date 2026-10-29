/// Strict UTF-8 scalar reading at any position of bytes that may not be valid UTF-8, forward and backward: the counterpart of the
/// lenient ``UTF8Decode``. A sequence is a scalar only when it is well formed (no overlong form, no surrogate, nothing above
/// U+10FFFF, every continuation byte present and in range); anything else is not a scalar, and ``step(_:at:)`` advances one byte past
/// it so a search always makes progress. Promoted from AemiRegex (aemi ADR 0018).
public enum UTF8Scalar {
    /// The width of the well-formed scalar that starts at `index`, or 1 when the bytes there are not one. The caller guarantees
    /// `index` is a valid index.
    @inlinable
    public static func width<C: RandomAccessCollection>(_ bytes: C, at index: Int) -> Int
    where C.Element == UInt8, C.Index == Int {
        let lead = bytes[index]
        let expected: Int
        var lowest: UInt8 = 0x80
        var highest: UInt8 = 0xBF
        switch lead {
            case 0x00 ... 0x7F: return 1
            case 0xC2 ... 0xDF: expected = 2
            case 0xE0:
                expected = 3
                lowest = 0xA0
            case 0xE1 ... 0xEC, 0xEE ... 0xEF: expected = 3
            case 0xED:
                expected = 3
                highest = 0x9F
            case 0xF0:
                expected = 4
                lowest = 0x90
            case 0xF1 ... 0xF3: expected = 4
            case 0xF4:
                expected = 4
                highest = 0x8F
            default: return 1
        }
        guard index + expected <= bytes.endIndex else { return 1 }
        guard (lowest ... highest).contains(bytes[index + 1]) else { return 1 }
        for offset in 2 ..< expected where !(0x80 ... 0xBF).contains(bytes[index + offset]) { return 1 }
        return expected
    }

    /// The scalar that starts at `index` and its width, or nil at the end or where the bytes are not a well-formed scalar.
    @inlinable
    public static func scalar<C: RandomAccessCollection>(_ bytes: C, at index: Int) -> (value: UInt32, width: Int)?
    where C.Element == UInt8, C.Index == Int {
        guard index >= bytes.startIndex, index < bytes.endIndex else { return nil }
        let lead = bytes[index]
        if lead < 0x80 { return (UInt32(lead), 1) }
        switch width(bytes, at: index) {
            case 2:
                return ((UInt32(lead & 0x1F) << 6) | UInt32(bytes[index + 1] & 0x3F), 2)
            case 3:
                let value =
                    (UInt32(lead & 0x0F) << 12) | (UInt32(bytes[index + 1] & 0x3F) << 6)
                    | UInt32(bytes[index + 2] & 0x3F)
                return (value, 3)
            case 4:
                let value =
                    (UInt32(lead & 0x07) << 18) | (UInt32(bytes[index + 1] & 0x3F) << 12)
                    | (UInt32(bytes[index + 2] & 0x3F) << 6) | UInt32(bytes[index + 3] & 0x3F)
                return (value, 4)
            default:
                return nil
        }
    }

    /// The scalar that ends at `index` and its width, or nil at the start or where the bytes before `index` are not a well-formed
    /// scalar.
    @inlinable
    public static func scalar<C: RandomAccessCollection>(_ bytes: C, before index: Int) -> (value: UInt32, width: Int)?
    where C.Element == UInt8, C.Index == Int {
        guard index > bytes.startIndex, index <= bytes.endIndex else { return nil }
        var start = index - 1
        var steps = 0
        while start > bytes.startIndex, steps < 3, bytes[start] & 0xC0 == 0x80 {
            start -= 1
            steps += 1
        }
        guard let found = scalar(bytes, at: start), start + found.width == index else { return nil }
        return found
    }

    /// The width of the scalar at `index`, or 1 when the bytes there are not well formed, so a search always advances.
    @inlinable
    public static func step<C: RandomAccessCollection>(_ bytes: C, at index: Int) -> Int
    where C.Element == UInt8, C.Index == Int {
        scalar(bytes, at: index)?.width ?? 1
    }
}

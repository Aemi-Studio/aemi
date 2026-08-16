/// ASCII classification primitives. The byte-level statics are the hot-path primitive used by the
/// scanners and codecs; the `Character` conveniences mirror them for grapheme-oriented callers
/// (e.g. URLBuilder's component validation). Consolidates the inline byte ranges scattered through
/// ADJSON with URLBuilder's `Character` helpers.
public enum ASCII {
    @inlinable public static func isDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }
    @inlinable public static func isUppercase(_ b: UInt8) -> Bool { b >= 0x41 && b <= 0x5A }
    @inlinable public static func isLowercase(_ b: UInt8) -> Bool { b >= 0x61 && b <= 0x7A }
    @inlinable public static func isAlpha(_ b: UInt8) -> Bool { isUppercase(b) || isLowercase(b) }
    @inlinable public static func isAlphanumeric(_ b: UInt8) -> Bool { isAlpha(b) || isDigit(b) }

    @inlinable
    public static func isHexDigit(_ b: UInt8) -> Bool {
        isDigit(b) || (b >= 0x41 && b <= 0x46) || (b >= 0x61 && b <= 0x66)
    }

    /// RFC 3986 §2.2 sub-delimiters: `! $ & ' ( ) * + , ; =`.
    @inlinable
    public static func isSubDelimiter(_ b: UInt8) -> Bool {
        switch b {
            case UInt8(ascii: "!"), UInt8(ascii: "$"), UInt8(ascii: "&"), UInt8(ascii: "'"),
                UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "*"), UInt8(ascii: "+"),
                UInt8(ascii: ","), UInt8(ascii: ";"), UInt8(ascii: "="):
                return true
            default:
                return false
        }
    }
}

extension Character {
    @inlinable public var isASCIIAlpha: Bool {
        ("a" ... "z").contains(self) || ("A" ... "Z").contains(self)
    }
    @inlinable public var isASCIIDigit: Bool { ("0" ... "9").contains(self) }
    @inlinable public var isASCIIAlphanumeric: Bool { isASCIIAlpha || isASCIIDigit }
    @inlinable public var isASCIIHexDigit: Bool {
        isASCIIDigit || ("a" ... "f").contains(self) || ("A" ... "F").contains(self)
    }
    @inlinable public var isSubDelimiter: Bool {
        switch self {
            case "!", "$", "&", "'", "(", ")", "*", "+", ",", ";", "=": true
            default: false
        }
    }
}

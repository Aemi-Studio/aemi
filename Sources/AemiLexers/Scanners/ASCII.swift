/// ASCII code points as bytes, and the character classes the scanners test UTF-8 bytes against. A byte of 128 or more
/// belongs to a multi-byte character, which counts as identifier text.
enum ASCII {
    static let newline: UInt8 = 10
    static let carriageReturn: UInt8 = 13
    static let quote: UInt8 = 34
    static let hash: UInt8 = 35
    static let ampersand: UInt8 = 38
    static let apostrophe: UInt8 = 39
    static let asterisk: UInt8 = 42
    static let hyphen: UInt8 = 45
    static let dot: UInt8 = 46
    static let slash: UInt8 = 47
    static let colon: UInt8 = 58
    static let semicolon: UInt8 = 59
    static let lessThan: UInt8 = 60
    static let equals: UInt8 = 61
    static let greaterThan: UInt8 = 62
    static let at: UInt8 = 64
    static let backslash: UInt8 = 92
    static let underscore: UInt8 = 95
    static let exclamation: UInt8 = 33
    static let dollar: UInt8 = 36
    static let percent: UInt8 = 37
    static let openBrace: UInt8 = 123
    static let closeBrace: UInt8 = 125
    static let openBracket: UInt8 = 91
    static let closeBracket: UInt8 = 93
    static let backtick: UInt8 = 96
    static let comma: UInt8 = 44
    static let plus: UInt8 = 43

    static func isDigit<Unit: BinaryInteger>(_ unit: Unit) -> Bool { unit >= 48 && unit <= 57 }
    static func isUpper<Unit: BinaryInteger>(_ unit: Unit) -> Bool { unit >= 65 && unit <= 90 }
    static func isLower<Unit: BinaryInteger>(_ unit: Unit) -> Bool { unit >= 97 && unit <= 122 }
    static func isAlpha<Unit: BinaryInteger>(_ unit: Unit) -> Bool { isUpper(unit) || isLower(unit) }
    static func isIdentifierStart<Unit: BinaryInteger>(_ unit: Unit) -> Bool {
        isAlpha(unit) || unit == underscore || unit >= 128
    }
    static func isIdentifier<Unit: BinaryInteger>(_ unit: Unit) -> Bool { isIdentifierStart(unit) || isDigit(unit) }
    static func isSpace<Unit: BinaryInteger>(_ unit: Unit) -> Bool {
        unit == 32 || unit == 9 || unit == newline || unit == carriageReturn
    }
}

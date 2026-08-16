// Helpers for emitting valid Swift source text from macro expansions. Pure `String` → `String`
// (no swift-syntax types), shared so each macro plugin stops re-rolling identifier backticking
// and string-literal escaping.

/// Emitting valid Swift source text from macro expansions — a caseless-enum namespace.
public enum SwiftSource {
    /// Swift reserved words that require backticks when used as a bare identifier.
    public static let keywords: Set<String> = [
        "as", "associatedtype", "break", "case", "catch", "class", "continue", "default", "defer",
        "deinit", "do", "else", "enum", "extension", "fallthrough", "false", "fileprivate", "for",
        "func", "guard", "if", "import", "in", "init", "inout", "internal", "is", "let", "nil",
        "operator", "private", "protocol", "public", "repeat", "rethrows", "return", "self",
        "static", "struct", "subscript", "super", "switch", "throw", "throws", "true", "try",
        "typealias", "var", "where", "while", "Any", "Self"
    ]

    /// Backtick-escapes `name` when it collides with a Swift reserved word, so emitted source such as
    /// `let ` + "`default`" + ` = …` compiles. Non-keyword names pass through unchanged.
    public static func escapedIdentifier(_ name: String) -> String {
        keywords.contains(name) ? "`\(name)`" : name
    }

    /// Renders `value` as a quoted Swift string literal safe to splice into emitted source.
    ///
    /// Escapes `\`, `"`, newline, carriage return, tab, and NUL, and renders any other control scalar
    /// (`< 0x20`) as `\u{…}` — so a value containing quotes, backslashes, newlines, or control
    /// characters can never terminate the literal early or change the meaning of the generated code.
    public static func stringLiteral(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
                case "\\": out += #"\\"#
                case "\"": out += #"\""#
                case "\n": out += #"\n"#
                case "\r": out += #"\r"#
                case "\t": out += #"\t"#
                case "\u{0}": out += #"\0"#
                default:
                    if scalar.value < 0x20 {
                        out += "\\u{"
                        out.append(hexDigit(scalar.value >> 4))
                        out.append(hexDigit(scalar.value & 0xF))
                        out += "}"
                    } else {
                        out.unicodeScalars.append(scalar)
                    }
            }
        }
        return out + "\""
    }

    private static func hexDigit(_ v: UInt32) -> Character {
        // `v` is a nibble (0...15), so the code unit is '0'...'9' / 'a'...'f' — always ASCII, fitting the
        // non-failable `UnicodeScalar(UInt8)` initializer (no force-unwrap).
        Character(UnicodeScalar(UInt8(v < 10 ? 0x30 + v : 0x61 + (v &- 10))))
    }
}

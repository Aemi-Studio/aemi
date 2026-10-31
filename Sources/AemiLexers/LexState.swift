/// Where a scanner stands at a line start, in 32 bits: in plain code, or inside a construct that
/// runs on across lines, a block comment, a string, a markup comment, declaration, tag or raw-text element, with what
/// closes it. A line scanned from the state the line before it ended in yields the tokens a whole-text scan gives it.
public struct LexState: Sendable, Hashable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// The state at a text's start: plain code, nothing open.
    public static let initial = LexState(rawValue: 0)
}

extension LexState {
    /// What a line starts inside of.
    enum Mode: UInt32 {
        case normal = 0
        /// A block comment; ``count`` is its nesting depth.
        case blockComment
        /// A string opened by ``quote``, tripled when ``isTriple``; ``count`` is a raw string's hashes.
        case string
        /// HTML's `<!-- … -->`.
        case markupComment
        /// HTML's `<! … >`.
        case declaration
        /// The attributes of an HTML tag; ``kind`` says whether it opens a `script` or `style` element.
        case tag
        /// A quoted attribute value, opened by ``quote``, in a tag of ``kind``.
        case attributeValue
        /// The body of a `script` or `style` element, per ``kind``, which no token colours.
        case rawText
    }

    /// The HTML element a tag opens, whose body the scanner skips.
    enum ElementKind: UInt32 {
        case other = 0
        case script
        case style
    }

    // Bits 0-3: the mode; 4-11: the quote; 12: tripled; 13-14: the element kind; 16-31: the count.
    init(mode: Mode, quote: UInt8 = 0, isTriple: Bool = false, kind: ElementKind = .other, count: Int = 0) {
        let saturated = UInt32(min(max(count, 0), 0xFFFF))
        rawValue =
            mode.rawValue | UInt32(quote) << 4 | (isTriple ? 1 << 12 : 0) | kind.rawValue << 13 | saturated << 16
    }

    var mode: Mode { Mode(rawValue: rawValue & 0xF) ?? .normal }
    var quote: UInt8 { UInt8(truncatingIfNeeded: rawValue >> 4) }
    var isTriple: Bool { rawValue & 1 << 12 != 0 }
    var kind: ElementKind { ElementKind(rawValue: rawValue >> 13 & 0x3) ?? .other }
    /// A block comment's depth, a raw string's hashes or CSS's brace depth, at most 65,535.
    var count: Int { Int(rawValue >> 16) }
}

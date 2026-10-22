extension Base64 {
    /// How `=` padding is treated.
    public enum PaddingPolicy: Sendable, Hashable {
        /// Decode: the text must be padded to a multiple of 4 (RFC 4648 §3.2). Encode: padding is written.
        case required
        /// Decode: padding may be absent, but if present it must be exactly the amount that completes
        /// the final group. Encode: padding is written.
        case optional
        /// Decode: `=` is rejected. Encode: padding is omitted (JWT and URL-token style).
        case forbidden
        /// Decode: any run of trailing `=` is ignored, however long (the historical behavior of the
        /// `Alphabet`-only API; never use it where ambiguity matters). Encode: padding is written.
        case tolerated
    }

    /// What to do with the unused low bits of the last symbol when the input does not end on a 3-byte
    /// boundary.
    public enum TrailingBitsPolicy: Sendable, Hashable {
        /// Reject non-zero leftover bits: exactly one text decodes to a given byte string.
        case canonical
        /// Ignore the leftover bits, so several texts decode to the same bytes.
        case lenient
    }

    /// Which non-alphabet bytes a decode skips.
    public enum WhitespacePolicy: Sendable, Hashable {
        /// Skip nothing; any byte outside the alphabet is an error.
        case reject
        /// Skip line breaks: `LF` and `CR LF`. A `CR` not followed by `LF` is an error.
        case skipLineBreaks
        /// Skip space, tab, vertical tab, form feed, and every `CR` and `LF`.
        case skipAll
    }

    /// The line separator an encode writes between wrapped lines. A decode that skips line breaks
    /// accepts both forms whatever this says.
    public enum LineEnding: Sendable, Hashable {
        case lf
        case crlf

        /// The separator length in bytes.
        var length: Int { self == .lf ? 1 : 2 }
    }

    /// How much a decode failure reveals.
    public enum ErrorReporting: Sendable, Hashable {
        /// Report the cause and the byte offset.
        case detailed
        /// Report ``DecodeError/malformed`` for every cause that depends on the input's content, so a
        /// remote party cannot use the error to probe the parser. This hides the cause only; it does not
        /// make the decoder constant-time.
        case uniform
    }

    /// Strictness and format of a Base64 encode or decode.
    ///
    /// Start from a preset and change fields, or build one with the memberwise initializer. The default
    /// value (``lenient``) matches the behavior of ``Base64/decode(_:alphabet:)``, so code that does not
    /// pass options is unchanged.
    ///
    /// | Preset | Alphabet | Padding | Leftover bits | Whitespace | Lines |
    /// | --- | --- | --- | --- | --- | --- |
    /// | ``strict`` | standard | required | canonical | rejected | none |
    /// | ``urlSafe`` | URL-safe | required | canonical | rejected | none |
    /// | ``urlSafeNoPadding`` | URL-safe | forbidden | canonical | rejected | none |
    /// | ``mime`` | standard | required | canonical | line breaks skipped | 76, CRLF |
    /// | ``pem`` | standard | required | canonical | line breaks skipped | 64, LF |
    /// | ``lenient`` | standard | any `=` run ignored | ignored | rejected | none |
    ///
    /// Use ``strict`` (or ``urlSafe`` / ``urlSafeNoPadding`` for those alphabets) for any text whose
    /// bytes are signed, hashed, or compared: it admits exactly one text per byte string, so two parsers
    /// cannot disagree about what was signed.
    public struct Options: Sendable, Hashable {
        /// The 64 symbols.
        public var alphabet: AlphabetTable
        /// Decode: which padding is accepted. Encode: padding is written unless this is `.forbidden`.
        public var padding: PaddingPolicy
        /// Decode only: how to treat non-zero leftover bits.
        public var trailingBits: TrailingBitsPolicy
        /// Decode only: which line breaks and spaces are skipped.
        public var whitespace: WhitespacePolicy
        /// Encode: wrap the output after this many characters. Decode: reject any line longer than this
        /// many characters (symbols and `=`, not line breaks); it applies only when ``whitespace``
        /// skips line breaks. `nil` means no wrapping and no limit. A value below 1 is treated as 1,
        /// which fails closed when decoding.
        public var lineLength: Int?
        /// Encode only: the separator written between wrapped lines (no separator is written after the
        /// last line).
        public var lineEnding: LineEnding
        /// Decode only: reject output longer than this many bytes. `nil` means no limit; a negative
        /// value is treated as 0.
        public var maximumDecodedSize: Int?
        /// Decode only: how much a failure reveals.
        public var errorReporting: ErrorReporting

        public init(
            alphabet: AlphabetTable = .standard,
            padding: PaddingPolicy = .tolerated,
            trailingBits: TrailingBitsPolicy = .lenient,
            whitespace: WhitespacePolicy = .reject,
            lineLength: Int? = nil,
            lineEnding: LineEnding = .lf,
            maximumDecodedSize: Int? = nil,
            errorReporting: ErrorReporting = .detailed
        ) {
            self.alphabet = alphabet
            self.padding = padding
            self.trailingBits = trailingBits
            self.whitespace = whitespace
            self.lineLength = lineLength
            self.lineEnding = lineEnding
            self.maximumDecodedSize = maximumDecodedSize
            self.errorReporting = errorReporting
        }

        /// RFC 4648 §4 with one canonical form per byte string: required padding (at most two `=`, only
        /// at the end), zero leftover bits, no whitespace, no bytes outside the alphabet.
        public static let strict = Options(
            padding: .required, trailingBits: .canonical, whitespace: .reject)

        /// RFC 4648 §5 (URL-safe alphabet), otherwise as strict as ``strict``.
        public static let urlSafe = Options(
            alphabet: .urlSafe, padding: .required, trailingBits: .canonical, whitespace: .reject)

        /// RFC 4648 §5 without padding (JWT, URL tokens), otherwise as strict as ``strict``.
        public static let urlSafeNoPadding = Options(
            alphabet: .urlSafe, padding: .forbidden, trailingBits: .canonical, whitespace: .reject)

        /// RFC 2045 MIME: 76-character lines separated by CRLF; decoding skips `LF` and `CR LF` and
        /// rejects longer lines. Otherwise canonical like ``strict``.
        public static let mime = Options(
            padding: .required, trailingBits: .canonical, whitespace: .skipLineBreaks,
            lineLength: 76, lineEnding: .crlf)

        /// RFC 7468 PEM body: 64-character lines separated by LF; decoding skips `LF` and `CR LF` and
        /// rejects longer lines. Otherwise canonical like ``strict``.
        public static let pem = Options(
            padding: .required, trailingBits: .canonical, whitespace: .skipLineBreaks,
            lineLength: 64, lineEnding: .lf)

        /// The behavior of ``Base64/decode(_:alphabet:)``: any trailing `=` run, leftover bits and
        /// all, no whitespace. The default for source compatibility; do not use it for security-relevant
        /// text.
        public static let lenient = Options()

        /// `lineLength` after clamping.
        var effectiveLineLength: Int? { lineLength.map { Swift.max(1, $0) } }
        /// `maximumDecodedSize` after clamping.
        var effectiveMaximumDecodedSize: Int? { maximumDecodedSize.map { Swift.max(0, $0) } }
        /// Whether an encode writes `=`.
        var writesPadding: Bool { padding != .forbidden }
    }
}

// MARK: - Sizing

extension Base64.Options {
    /// The exact length of the encoding of `byteCount` bytes under these options (padding, line
    /// separators included), or `nil` if it does not fit in `Int`.
    public func encodedLength(forByteCount byteCount: Int) -> Int? {
        guard byteCount >= 0 else { return nil }
        let remainder = byteCount % 3
        let tail = remainder == 0 ? 0 : (writesPadding ? 4 : remainder + 1)
        let (groups, groupOverflow) = (byteCount / 3).multipliedReportingOverflow(by: 4)
        let (symbols, sumOverflow) = groups.addingReportingOverflow(tail)
        guard !groupOverflow, !sumOverflow else { return nil }
        guard let width = effectiveLineLength, symbols > 0 else { return symbols }
        let separators = (symbols - 1) / width
        let (extra, extraOverflow) = separators.multipliedReportingOverflow(by: lineEnding.length)
        let (total, totalOverflow) = symbols.addingReportingOverflow(extra)
        return extraOverflow || totalOverflow ? nil : total
    }

    /// An upper bound on the decoded size of `encodedCount` input bytes. It is exact for unpadded,
    /// unwrapped text and otherwise at most a few bytes high, so it is the right size for a buffer
    /// passed to `decode(_:into:options:)`. It ignores ``maximumDecodedSize``.
    public func maximumDecodedLength(forEncodedCount encodedCount: Int) -> Int {
        guard encodedCount > 0 else { return 0 }
        return encodedCount / 4 * 3 + Swift.max(0, encodedCount % 4 - 1)
    }
}

/// Base64 (RFC 4648). Domain-neutral and `Foundation`-free, in the style of ``Hex`` and
/// ``PercentCoding``: iterative (no recursion) and no-trap — a malformed input is an error value,
/// never a crash, matching the byte kernel's no-trap-at-boundaries rule.
///
/// Behavior is chosen per use case with ``Options``: the standard or URL-safe alphabet (or a validated
/// custom one), required, optional, or forbidden `=` padding, canonical or lenient leftover bits, and
/// whether and how line breaks and spaces are skipped. The presets cover the common cases:
///
/// - ``Options/strict``, ``Options/urlSafe``, ``Options/urlSafeNoPadding``: exactly one text per byte
///   string. Use these for anything signed, hashed, or compared (OpenPGP armor, JWT, tokens).
/// - ``Options/mime``, ``Options/pem``: wrapped lines, line breaks skipped, line length enforced.
/// - ``Options/lenient``: the historical behavior, and the default of the `Alphabet`-only API.
///
/// ```swift
/// let bytes = try Base64.decode(armorBody, options: .strict)       // throws DecodeError
/// let token = Base64.encodedString(digest, options: .urlSafeNoPadding)
/// let pem   = Base64.encodedString(der, options: .pem)             // 64-column lines
/// ```
///
/// Decoding contiguous input (`Array`, `ArraySlice`, a native `String.utf8`, a `Span`) takes a
/// table-driven fast path, and `decode(_:into:options:)` / `encode(_:into:options:)` write into a
/// caller buffer without allocating.
public enum Base64 {
    /// The 64-character alphabet. ``standard`` is RFC 4648 §4 (`+`/`/`); ``urlSafe`` is §5 (`-`/`_`),
    /// the form safe inside URLs and filenames.
    public enum Alphabet: Sendable, Hashable {
        case standard
        case urlSafe
    }

    /// Base64-encodes `bytes`. With `padding` (default), the output is `=`-padded to a multiple of 4;
    /// without it, the padding is omitted (the common URL-safe convention). Allowed bytes only — every
    /// input byte is encoded, so this never fails. For line wrapping or a custom alphabet, use
    /// ``encode(_:options:)``.
    public static func encode(
        _ bytes: some Collection<UInt8>, alphabet: Alphabet = .standard, padding: Bool = true
    ) -> [UInt8] {
        encode(bytes, options: Options(alphabet: AlphabetTable(alphabet), padding: padding ? .required : .forbidden))
    }

    /// Base64-encodes `bytes` and returns the result as a `String` (the encoding is always ASCII).
    public static func encodedString(
        _ bytes: some Collection<UInt8>, alphabet: Alphabet = .standard, padding: Bool = true
    ) -> String {
        String(decoding: encode(bytes, alphabet: alphabet, padding: padding), as: UTF8.self)
    }

    /// Decodes base64 `bytes`. Accepts input with or without `=` padding; returns `nil` (never traps)
    /// on any character outside `alphabet`, on data after a `=`, or on an impossible length (a lone
    /// trailing sextet). Non-canonical trailing bits are tolerated, as is a `=` run of any length. No
    /// whitespace is skipped.
    ///
    /// This is the ``Options/lenient`` decode and is kept for source compatibility. It cannot say why
    /// a decode failed and it accepts several texts for one byte string, so for security-relevant
    /// input call ``decode(_:options:)`` with ``Options/strict``.
    public static func decode(_ bytes: some Collection<UInt8>, alphabet: Alphabet = .standard) -> [UInt8]? {
        try? decode(bytes, options: Options(alphabet: AlphabetTable(alphabet)))
    }

    @usableFromInline static let padByte = UInt8(ascii: "=")
}

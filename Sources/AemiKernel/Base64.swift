/// Base64 (RFC 4648). Domain-neutral and `Foundation`-free, built on ``OutputSpan`` like ``Hex`` and
/// ``PercentCoding``: iterative (no recursion) and no-trap — ``decode(_:alphabet:)`` returns `nil` on
/// malformed input rather than crashing, matching the byte kernel's no-trap-at-boundaries rule. Both
/// the standard (`+`/`/`, §4) and URL-safe (`-`/`_`, §5) alphabets are supported, with optional `=`
/// padding. Consolidates the standard-alphabet encoder that lived in `ADHTMLSRI` (SRI `sha256-…`
/// tokens) so the AD* family shares one base64 implementation.
///
/// Cold path by design (SRI digests, cache-busting artifact names, small config blobs), so the codec
/// favors clarity over the `@inlinable` hot-loop treatment ``Hex`` / ``SWAR`` get.
public enum Base64 {
    /// The 64-character alphabet. ``standard`` is RFC 4648 §4 (`+`/`/`); ``urlSafe`` is §5 (`-`/`_`),
    /// the form safe inside URLs and filenames.
    public enum Alphabet: Sendable, Hashable {
        case standard
        case urlSafe
    }

    /// Base64-encodes `bytes`. With `padding` (default), the output is `=`-padded to a multiple of 4;
    /// without it, the padding is omitted (the common URL-safe convention). Allowed bytes only — every
    /// input byte is encoded, so this never fails.
    public static func encode(
        _ bytes: some Collection<UInt8>, alphabet: Alphabet = .standard, padding: Bool = true
    ) -> [UInt8] {
        let table = alphabet == .standard ? standardEncode : urlSafeEncode
        let n = bytes.count
        let fullGroups = n / 3
        let remainder = n % 3
        // Exact output size: 4 chars per full 3-byte group; a 1- or 2-byte tail is 2 or 3 chars, rounded
        // up to 4 with `=` when padding. Sizing the `OutputSpan` exactly means a single allocation, no
        // CoW, and bounds-checked appends.
        let tailCount = remainder == 0 ? 0 : (padding ? 4 : remainder + 1)
        let outCount = fullGroups * 4 + tailCount
        return [UInt8](capacity: outCount) { span in
            var iterator = bytes.makeIterator()
            for _ in 0 ..< fullGroups {
                guard let b0 = iterator.next(), let b1 = iterator.next(), let b2 = iterator.next() else {
                    return
                }
                let chunk = (UInt32(b0) << 16) | (UInt32(b1) << 8) | UInt32(b2)
                span.append(table[Int((chunk >> 18) & 0x3F)])
                span.append(table[Int((chunk >> 12) & 0x3F)])
                span.append(table[Int((chunk >> 6) & 0x3F)])
                span.append(table[Int(chunk & 0x3F)])
            }
            if remainder == 1, let b0 = iterator.next() {
                let chunk = UInt32(b0) << 16
                span.append(table[Int((chunk >> 18) & 0x3F)])
                span.append(table[Int((chunk >> 12) & 0x3F)])
                if padding {
                    span.append(padByte)
                    span.append(padByte)
                }
            } else if remainder == 2, let b0 = iterator.next(), let b1 = iterator.next() {
                let chunk = (UInt32(b0) << 16) | (UInt32(b1) << 8)
                span.append(table[Int((chunk >> 18) & 0x3F)])
                span.append(table[Int((chunk >> 12) & 0x3F)])
                span.append(table[Int((chunk >> 6) & 0x3F)])
                if padding { span.append(padByte) }
            }
        }
    }

    /// Base64-encodes `bytes` and returns the result as a `String` (the encoding is always ASCII).
    public static func encodedString(
        _ bytes: some Collection<UInt8>, alphabet: Alphabet = .standard, padding: Bool = true
    ) -> String {
        String(decoding: encode(bytes, alphabet: alphabet, padding: padding), as: UTF8.self)
    }

    /// Decodes base64 `bytes`. Accepts input with or without `=` padding; returns `nil` (never traps)
    /// on any character outside `alphabet`, on data after a `=`, or on an impossible length (a lone
    /// trailing sextet). Non-canonical trailing bits are tolerated. No whitespace is skipped — strip it
    /// at the call site if the source allows it.
    public static func decode(_ bytes: some Collection<UInt8>, alphabet: Alphabet = .standard) -> [UInt8]? {
        let reverse = alphabet == .standard ? standardDecode : urlSafeDecode
        // Each 4 input chars yield at most 3 bytes; `(count / 4 + 1) * 3` is a safe upper bound for the
        // exclusively-owned output buffer. Invalid input flips the flag and the partial buffer is dropped.
        var invalid = false
        let result = [UInt8](capacity: (bytes.count / 4 + 1) * 3) { span in
            var group: UInt32 = 0
            var count = 0
            var sawPadding = false
            var iterator = bytes.makeIterator()
            while let c = iterator.next() {
                if c == padByte {
                    sawPadding = true
                    continue
                }
                // A data byte after a `=` is malformed (`=` may only trail).
                guard !sawPadding else {
                    invalid = true
                    return
                }
                let value = reverse[Int(c)]
                guard value >= 0 else {
                    invalid = true
                    return
                }
                group = (group << 6) | UInt32(value)
                count += 1
                if count == 4 {
                    span.append(UInt8((group >> 16) & 0xFF))
                    span.append(UInt8((group >> 8) & 0xFF))
                    span.append(UInt8(group & 0xFF))
                    group = 0
                    count = 0
                }
            }
            switch count {
                case 0: break
                case 2: span.append(UInt8((group >> 4) & 0xFF))  // 12 bits → 1 byte (low 4 are pad)
                case 3:  // 18 bits → 2 bytes (low 2 are pad)
                    span.append(UInt8((group >> 10) & 0xFF))
                    span.append(UInt8((group >> 2) & 0xFF))
                default: invalid = true  // a lone trailing sextet (8 bits) cannot form a byte
            }
        }
        return invalid ? nil : result
    }

    // MARK: - Tables

    @usableFromInline static let padByte = UInt8(ascii: "=")

    /// RFC 4648 §4 alphabet (`A–Z a–z 0–9 + /`).
    static let standardEncode: [UInt8] = Array(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)
    /// RFC 4648 §5 URL/filename-safe alphabet (`+`→`-`, `/`→`_`).
    static let urlSafeEncode: [UInt8] = Array(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8)

    /// Byte → 0–63 sextet value (`-1` = not in the alphabet).
    static let standardDecode: [Int8] = reverseTable(standardEncode)
    static let urlSafeDecode: [Int8] = reverseTable(urlSafeEncode)

    private static func reverseTable(_ encode: [UInt8]) -> [Int8] {
        var table = [Int8](repeating: -1, count: 256)
        for (index, byte) in encode.enumerated() { table[Int(byte)] = Int8(index) }
        return table
    }
}

# Base64

`AemiKernel` encodes and decodes Base64 (RFC 4648) with the strictness each use needs. Pick a preset
of `Base64.Options`; every decode reports why it failed with a typed `Base64.DecodeError`, including
the byte offset.

| Preset | Use it for |
| --- | --- |
| `.strict` | **Signature-bearing or security-relevant text**, such as OpenPGP armor bodies, hashes, and anything compared byte for byte. Padding required, exactly one canonical text per byte string, no whitespace, no stray bytes. |
| `.urlSafe`, `.urlSafeNoPadding` | URL and filename tokens (RFC 4648 section 5): JWT segments, data URLs, query values. As strict as `.strict`. |
| `.mime` | Email bodies: 76-column lines, CRLF on encode, `LF` and `CR LF` skipped on decode, longer lines rejected. |
| `.pem` | PEM bodies: 64-column lines, LF on encode, line breaks skipped on decode. |
| `.lenient` | The default of `Base64.decode(_:alphabet:)`: any `=` run, non-zero leftover bits. |

```swift
import AemiKernel

// Strict, canonical armor: throws on any ambiguity.
let payload = try Base64.decode(armorBody, options: .strict)

// URL-safe, unpadded token.
let token = Base64.encodedString(digest, options: .urlSafeNoPadding)

// MIME / PEM bodies: wrapped lines are produced and accepted.
let mime = Base64.encodedString(attachment, options: .mime)
let der = try Base64.decode(pemBody, options: .pem)

// No allocation: decode into a buffer sized with the upper bound.
var buffer = [UInt8](repeating: 0, count: Base64.Options.strict.maximumDecodedLength(forEncodedCount: text.utf8.count))
let count = try buffer.withUnsafeMutableBufferPointer { out in
    try Base64.decode(text.utf8, into: out, options: .strict)
}
```

A preset is a value: change a field to tune it (`var options = Base64.Options.pem; options.maximumDecodedSize = 1 << 20`),
set `errorReporting = .uniform` to hide the failure cause from remote parties, or supply a validated
custom alphabet with `Base64.AlphabetTable(symbols:)`. Contiguous input (`Array`, `ArraySlice`, a
native `String`'s UTF-8, `Span`) takes a table-driven fast path.

/// RFC 3986 percent-coding over bytes. Domain-neutral: the caller supplies the `allowed` predicate
/// (the safe set for its grammar — a path segment, a query component, userinfo, …), so URL- or
/// JSON-specific policy stays at the call site while the escaping mechanics live here once. Built on
/// ``Hex`` and ``ASCII``; iterative (no recursion) and never traps on malformed input — a bad escape
/// decodes to `nil`, matching the byte kernel's no-trap-at-boundaries rule. Consolidates the
/// percent-coding that ADJSON and URLBuilder each carried.
public enum PercentCoding {
    /// RFC 3986 §2.3 unreserved set — `ALPHA / DIGIT / "-" / "." / "_" / "~"` — the bytes that never
    /// need escaping in any URI component. A neutral default for ``encode(_:)``; callers with a
    /// stricter or looser grammar pass their own predicate to ``encode(_:allowed:)``.
    @inlinable
    public static func isUnreserved(_ b: UInt8) -> Bool {
        ASCII.isAlphanumeric(b)
            || b == UInt8(ascii: "-") || b == UInt8(ascii: ".")
            || b == UInt8(ascii: "_") || b == UInt8(ascii: "~")
    }

    /// Percent-encodes `bytes`: each byte for which `allowed` returns `false` becomes a `%XX` triple
    /// with uppercase hex (RFC 3986 §2.1); allowed bytes are copied verbatim.
    @inlinable
    public static func encode(_ bytes: some Sequence<UInt8>, allowed: (UInt8) -> Bool) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.underestimatedCount)
        for b in bytes {
            if allowed(b) {
                out.append(b)
            } else {
                out.append(UInt8(ascii: "%"))
                out.append(Hex.upperDigit(b >> 4))
                out.append(Hex.upperDigit(b & 0x0F))
            }
        }
        return out
    }

    /// Percent-encodes `bytes`, escaping everything outside the RFC 3986 ``isUnreserved(_:)`` set.
    @inlinable
    public static func encode(_ bytes: some Sequence<UInt8>) -> [UInt8] {
        encode(bytes, allowed: isUnreserved)
    }

    /// Percent-decodes `bytes`, turning each `%XX` triple back into its byte and copying everything
    /// else verbatim. Returns `nil` on a truncated (`"%"`, `"%A"`) or non-hex (`"%G0"`) escape rather
    /// than trapping. A literal `"+"` is left as-is (RFC 3986); use ``decodeForm(_:)`` when you need the
    /// `application/x-www-form-urlencoded` `"+"`→space rule (query components, HTML form bodies).
    @inlinable
    public static func decode(_ bytes: some Collection<UInt8>) -> [UInt8]? {
        decode(bytes, plusAsSpace: false)
    }

    /// Percent-decodes `bytes` as `application/x-www-form-urlencoded`: identical to ``decode(_:)``
    /// except a literal `"+"` becomes a space (`0x20`) — the rule for URL query components and HTML
    /// form bodies. Returns `nil` on a malformed escape, exactly like ``decode(_:)``. Decoding the
    /// query string through one audited primitive (rather than a per-call hand-rolled loop) is also the
    /// safe choice: the `nil` lets the caller reject malformed input instead of silently mis-decoding.
    @inlinable
    public static func decodeForm(_ bytes: some Collection<UInt8>) -> [UInt8]? {
        decode(bytes, plusAsSpace: true)
    }

    /// Shared decoder core. Percent-decodes `bytes`; when `plusAsSpace` is `true`, a literal `"+"` maps
    /// to a space (`0x20`) per `application/x-www-form-urlencoded`, otherwise it is copied verbatim per
    /// RFC 3986. Returns `nil` on a truncated or non-hex escape rather than trapping.
    @inlinable
    public static func decode(_ bytes: some Collection<UInt8>, plusAsSpace: Bool) -> [UInt8]? {
        // Decoding only ever copies or shrinks, so `bytes.count` is an exact upper bound: build into a
        // single, exclusively-owned `OutputSpan` sized to it (back-deploys to the floor; no
        // `reserveCapacity` foot-gun, bounds-checked writes, no CoW). A malformed escape sets the flag
        // and bails; the partially-built buffer is then discarded for the documented `nil`.
        var malformed = false
        let result = [UInt8](capacity: bytes.count) { span in
            var iterator = bytes.makeIterator()
            while let b = iterator.next() {
                if plusAsSpace, b == UInt8(ascii: "+") {
                    span.append(UInt8(ascii: " "))
                    continue
                }
                guard b == UInt8(ascii: "%") else {
                    span.append(b)
                    continue
                }
                guard let high = iterator.next(), let highValue = Hex.value(high),
                    let low = iterator.next(), let lowValue = Hex.value(low)
                else {
                    malformed = true
                    return
                }
                span.append(highValue << 4 | lowValue)
            }
        }
        return malformed ? nil : result
    }
}

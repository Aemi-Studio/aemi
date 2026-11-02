internal import AemiKernels

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
    ///
    /// Contiguous input of 64 bytes or more whose escaped bytes form a set the SIMD kernels can hold (most grammars' sets do)
    /// is encoded 16 bytes at a time; `allowed` is then asked once per byte value rather than once per byte.
    public static func encode(_ bytes: some Sequence<UInt8>, allowed: (UInt8) -> Bool) -> [UInt8] {
        let fast = bytes.withContiguousStorageIfAvailable { buffer -> [UInt8]? in
            guard buffer.count >= 64 else { return nil }
            let escaped = (0 ... 255).map { UInt8($0) }.filter { !allowed($0) }
            guard let set = AemiKernels.ByteSet(escaped) else { return nil }
            return unsafe encode(buffer, escaping: set)
        }
        if let fast, let fast { return fast }
        return encodeByteByByte(bytes, allowed: allowed)
    }

    /// Percent-encodes `bytes`, escaping every byte outside the RFC 3986 unreserved set (``isUnreserved(_:)``).
    public static func encode(_ bytes: some Sequence<UInt8>) -> [UInt8] {
        let fast = bytes.withContiguousStorageIfAvailable { unsafe encode($0, escaping: reservedSet) }
        return fast ?? encodeByteByByte(bytes, allowed: isUnreserved)
    }

    /// Percent-decodes `bytes` (RFC 3986): `%XX` (either hex case) becomes its byte, every other byte is copied. Returns `nil`
    /// for a `%` not followed by two hex digits.
    public static func decode(_ bytes: some Collection<UInt8>) -> [UInt8]? {
        decode(bytes, plusAsSpace: false)
    }

    /// Percent-decodes `bytes` as `application/x-www-form-urlencoded`: as ``decode(_:)``, and a literal `+` becomes a space.
    public static func decodeForm(_ bytes: some Collection<UInt8>) -> [UInt8]? {
        decode(bytes, plusAsSpace: true)
    }

    /// Percent-decodes `bytes`, with `+` as a space when `plusAsSpace`. Contiguous input is decoded 16 bytes at a time
    /// wherever a block holds no escape.
    public static func decode(_ bytes: some Collection<UInt8>, plusAsSpace: Bool) -> [UInt8]? {
        let fast = bytes.withContiguousStorageIfAvailable { buffer -> [UInt8]? in
            var malformed = false
            // Decoding only ever copies or shrinks, so the input's length is an upper bound.
            let result = unsafe [UInt8](unsafeUninitializedCapacity: buffer.count) { out, initialized in
                initialized = 0
                if let written = unsafe AemiKernels.percentDecode(buffer, into: out, plusAsSpace: plusAsSpace) {
                    initialized = written
                } else {
                    malformed = true
                }
            }
            return malformed ? nil : result
        }
        if let fast { return fast }
        return decodeByteByByte(bytes, plusAsSpace: plusAsSpace)
    }

    // MARK: - Plumbing

    /// The bytes ``encode(_:)`` escapes: everything but the unreserved set, which fits the kernels' nibble tables (six rows).
    static let reservedSet: AemiKernels.ByteSet = {
        guard let set = AemiKernels.ByteSet((0 ... 255).map { UInt8($0) }.filter { !isUnreserved($0) }) else {
            preconditionFailure("PercentCoding: the reserved set must fit the kernel's tables")
        }
        return set
    }()

    private static func encode(_ input: UnsafeBufferPointer<UInt8>, escaping set: AemiKernels.ByteSet) -> [UInt8] {
        let escapes = unsafe AemiKernels.count(inSet: set, in: input)
        let (extra, overflow1) = escapes.multipliedReportingOverflow(by: 2)
        let (total, overflow2) = input.count.addingReportingOverflow(extra)
        precondition(!overflow1 && !overflow2, "PercentCoding: the encoded length overflows Int")
        return unsafe [UInt8](unsafeUninitializedCapacity: total) { out, initialized in
            initialized = 0
            unsafe AemiKernels.percentEncode(input, escaping: set, into: out)
            initialized = total
        }
    }

    private static func encodeByteByByte(_ bytes: some Sequence<UInt8>, allowed: (UInt8) -> Bool) -> [UInt8] {
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

    private static func decodeByteByByte(_ bytes: some Collection<UInt8>, plusAsSpace: Bool) -> [UInt8]? {
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

//
//  AemiKernels.swift
//  AemiKernels
//
//  The pure-Swift facade over `CAemiKernels`' runtime-dispatched SIMD byte kernels. Each operation
//  picks the widest ISA available on this CPU (AVX2/SSE4.2/SSE2 on x86-64, NEON on arm64, scalar
//  elsewhere), detected once and cached in C. Contiguous input drives the accelerated C kernel; a
//  non-contiguous `Sequence` uses a pure-Swift scalar path (also the differential-test reference).
//  Every backend agrees byte-for-byte with the scalar reference. Iterative; no recursion.
//
//  Built with SE-0458 strict memory safety (like `AemiKernel`): every pointer construction / C call is
//  spelled `unsafe`, and the pointer-taking entry points are the caller's `unsafe` boundary.
//

internal import CAemiKernels

/// Runtime-dispatched SIMD byte kernels shared across the AD* family (JSON string scanning, FTS/key
/// ASCII folding, byte search). See `CAemiKernels` for the per-ISA implementations.
public enum AemiKernels {
    /// A specific kernel backend. Every backend produces identical results — they differ only in the
    /// ISA used, and each named backend self-guards (falls back when its CPU feature is unavailable),
    /// so any case is safe to request on any host. Non-`fastest` cases exist for differential tests
    /// and benchmarks.
    public enum Backend: Sendable {
        /// The widest backend available on this CPU (the default).
        case fastest
        /// Portable scalar reference — the cross-check oracle.
        case scalar
        /// x86-64 SSE2 (128-bit); falls back to scalar off x86-64.
        case sse2
        /// x86-64 AVX2 (256-bit); falls back to SSE2/scalar when AVX2 is absent (e.g. under Rosetta).
        case avx2
        /// arm64 NEON (128-bit); falls back to scalar off arm64.
        case neon
    }

    /// The name of the widest ISA tier selected on this CPU (e.g. `"avx2"`, `"neon+dotprod"`, `"sse4.2"`,
    /// `"scalar"`) — for logging and benchmark labels.
    public static var activeBackend: String {
        unsafe String(cString: adf_kernels_backend())
    }

    // MARK: - Date parsing (byte-level, Foundation-free)

    /// Parse the canonical UTC ISO-8601 timestamp `YYYY-MM-DDTHH:MM:SSZ` (exactly `count == 20` bytes) at
    /// `buf` into seconds since the Unix epoch, or `nil` to defer to a full date library — for any other
    /// length/shape/range, a non-canonical spelling, the 1582 Gregorian-reform year, or a year < 1.
    /// Julian calendar before the 1582-10-15 reform, Gregorian on/after (matching Foundation's
    /// `.iso8601`). Lets a caller parse straight from a tape / socket buffer with no intermediate `String`.
    ///
    /// Owner/bounds: the caller owns `buf[0..<count]` for the call; it does not escape.
    public static func parseISO8601UTCSeconds(_ buf: UnsafePointer<UInt8>, count: Int) -> Int64? {
        var seconds: Int64 = 0
        let ok = unsafe adf_parse_iso8601_utc(buf, count, &seconds)
        return ok != 0 ? seconds : nil
    }

    // MARK: - ASCII fold (A–Z → a–z)

    /// Lowercase ASCII `A`–`Z` in `src[0..<count]`, writing `count` bytes to `dst`. `dst` may equal
    /// `src` (in-place); otherwise the ranges must not overlap. Non-ASCII bytes are copied unchanged.
    ///
    /// Owner/bounds: the caller owns `dst[0..<count]` and `src[0..<count]` for the call; neither escapes.
    public static func foldASCII(
        into dst: UnsafeMutablePointer<UInt8>,
        from src: UnsafePointer<UInt8>,
        count: Int,
        backend: Backend = .fastest
    ) {
        guard count > 0 else { return }
        switch backend {
            case .fastest: unsafe adf_fold_ascii(dst, src, count)
            case .scalar: unsafe adf_fold_ascii_scalar(dst, src, count)
            case .sse2: unsafe adf_fold_ascii_sse2(dst, src, count)
            case .avx2: unsafe adf_fold_ascii_avx2(dst, src, count)
            case .neon: unsafe adf_fold_ascii_neon(dst, src, count)
        }
    }

    /// A copy of `bytes` with ASCII `A`–`Z` lowercased (other bytes unchanged).
    public static func foldedASCII(_ bytes: [UInt8], backend: Backend = .fastest) -> [UInt8] {
        let count = bytes.count
        guard count > 0 else { return [] }
        return unsafe [UInt8](unsafeUninitializedCapacity: count) { out, initialized in
            guard let dst = out.baseAddress else {
                initialized = 0
                return
            }
            bytes.withUnsafeBufferPointer { src in
                guard let base = src.baseAddress else { return }
                unsafe foldASCII(into: dst, from: base, count: count, backend: backend)
            }
            initialized = count
        }
    }

    // MARK: - JSON-style string-stop scan

    /// The offset within `base[0..<count]` of the first byte a JSON/wire string reader must stop on —
    /// a control byte (`< 0x20`), a non-ASCII byte (`>= 0x80`), the `quote`, or the `escape` — or
    /// `count` if every byte is plain ASCII content. Matches ADJSON's `stringStopMask`.
    ///
    /// Owner/bounds: the caller owns `base[0..<count]` for the call; it never escapes.
    public static func indexOfStringStop(
        base: UnsafePointer<UInt8>,
        count: Int,
        quote: UInt8,
        escape: UInt8,
        backend: Backend = .fastest
    ) -> Int {
        guard count > 0 else { return 0 }
        switch backend {
            case .fastest: return unsafe adf_index_of_string_stop(base, count, quote, escape)
            case .scalar: return unsafe adf_index_of_string_stop_scalar(base, count, quote, escape)
            case .sse2: return unsafe adf_index_of_string_stop_sse2(base, count, quote, escape)
            case .avx2: return unsafe adf_index_of_string_stop_avx2(base, count, quote, escape)
            case .neon: return unsafe adf_index_of_string_stop_neon(base, count, quote, escape)
        }
    }

    /// The index in `bytes` of the first string-stop byte (see ``indexOfStringStop(base:count:quote:escape:backend:)``),
    /// or `nil` if the whole buffer is plain content.
    public static func indexOfStringStop(
        _ bytes: [UInt8],
        quote: UInt8,
        escape: UInt8,
        backend: Backend = .fastest
    ) -> Int? {
        let count = bytes.count
        guard count > 0 else { return nil }
        let index = bytes.withUnsafeBufferPointer { src -> Int in
            guard let base = src.baseAddress else { return count }
            return unsafe indexOfStringStop(
                base: base, count: count, quote: quote, escape: escape, backend: backend)
        }
        return index == count ? nil : index
    }

    // MARK: - Single-byte search

    /// The offset within `base[0..<count]` of the first byte equal to `needle`, or `count` if absent.
    /// Routes to libc `memchr` (already vectorized); `.scalar` forces the plain reference loop.
    public static func firstIndexOfByte(
        base: UnsafePointer<UInt8>,
        count: Int,
        needle: UInt8,
        backend: Backend = .fastest
    ) -> Int {
        guard count > 0 else { return 0 }
        if case .scalar = backend {
            return unsafe adf_index_of_byte_scalar(base, count, needle)
        }
        return unsafe adf_index_of_byte(base, count, needle)
    }

    /// The index in `bytes` of the first byte equal to `needle`, or `nil` if absent.
    public static func firstIndexOfByte(
        _ needle: UInt8,
        in bytes: [UInt8],
        backend: Backend = .fastest
    ) -> Int? {
        let count = bytes.count
        guard count > 0 else { return nil }
        let index = bytes.withUnsafeBufferPointer { src -> Int in
            guard let base = src.baseAddress else { return count }
            return unsafe firstIndexOfByte(base: base, count: count, needle: needle, backend: backend)
        }
        return index == count ? nil : index
    }

    // MARK: - First byte in a small literal set

    /// The offset within `base[0..<count]` of the first byte equal to any of `n0…n4` (repeat a needle
    /// to use fewer than five, e.g. an HTML text escaper passes `& < >` with `n3 = n4 = n0`), or
    /// `count` if none. `.scalar` forces the reference loop; any other backend uses the dispatched SIMD.
    // The five needles are a fixed-arity SIMD contract, not a parameter list that grew: they load
    // straight into vector lanes, and callers repeat a needle to use fewer. Passing them as a
    // tuple or array would either add an indirection on the hot path or break 18 call sites
    // across ADJSON / ADHTML / HTTP for a metric.
    // swiftlint:disable:next function_parameter_count
    public static func firstIndexOfAny(
        base: UnsafePointer<UInt8>,
        count: Int,
        _ n0: UInt8, _ n1: UInt8, _ n2: UInt8, _ n3: UInt8, _ n4: UInt8,
        backend: Backend = .fastest
    ) -> Int {
        guard count > 0 else { return 0 }
        if case .scalar = backend {
            return unsafe adf_index_of_any5_scalar(base, count, n0, n1, n2, n3, n4)
        }
        return unsafe adf_index_of_any5(base, count, n0, n1, n2, n3, n4)
    }

    // MARK: - Printable-text validation

    /// The offset within `base[0..<count]` of the first byte that is NOT legal printable wire text — a
    /// control byte below `minAllowed` (with an optional HTAB `0x09` exception when `allowTab`) or DEL
    /// `0x7F`; obs-text `>= 0x80` is legal — or `count` if all legal. RFC 9110 field-value:
    /// `minAllowed: 0x20, allowTab: true`; request-target: `0x21, false`. `.scalar` forces the reference.
    public static func firstDisallowedText(
        base: UnsafePointer<UInt8>,
        count: Int,
        minAllowed: UInt8,
        allowTab: Bool,
        backend: Backend = .fastest
    ) -> Int {
        guard count > 0 else { return 0 }
        if case .scalar = backend {
            return unsafe adf_first_disallowed_text_scalar(base, count, minAllowed, allowTab ? 1 : 0)
        }
        return unsafe adf_first_disallowed_text(base, count, minAllowed, allowTab ? 1 : 0)
    }

    // MARK: - First control byte or literal (escape-on-write scan)

    /// The offset within `base[0..<count]` of the first byte that is a control byte (`< 0x20`) OR equal
    /// to any of `n0…n4` (repeat a needle to use fewer), or `count` if none. Bytes `>= 0x80` are not
    /// stops (a JSON serializer copies well-formed UTF-8 verbatim). `.scalar` forces the reference.
    // Fixed-arity SIMD contract — see `firstIndexOfAny` above.
    // swiftlint:disable:next function_parameter_count
    public static func indexOfControlOrAny(
        base: UnsafePointer<UInt8>,
        count: Int,
        _ n0: UInt8, _ n1: UInt8, _ n2: UInt8, _ n3: UInt8, _ n4: UInt8,
        backend: Backend = .fastest
    ) -> Int {
        guard count > 0 else { return 0 }
        if case .scalar = backend {
            return unsafe adf_index_of_control_or_any5_scalar(base, count, n0, n1, n2, n3, n4)
        }
        return unsafe adf_index_of_control_or_any5(base, count, n0, n1, n2, n3, n4)
    }

    // MARK: - Full UTF-8 validation (multibyte in-vector)

    /// The offset of the first byte in `base[0..<count]` that is not part of well-formed UTF-8 (RFC
    /// 3629 — invalid leads, bad/short continuations, overlong forms, surrogates, > U+10FFFF), or
    /// `count` if the whole buffer is well-formed. Validates multi-byte sequences in-vector.
    public static func firstInvalidUTF8(
        base: UnsafePointer<UInt8>,
        count: Int,
        backend: Backend = .fastest
    ) -> Int {
        guard count > 0 else { return 0 }
        if case .scalar = backend {
            return unsafe adf_first_invalid_utf8_scalar(base, count)
        }
        return unsafe adf_first_invalid_utf8(base, count)
    }

    /// The index of the first byte in `bytes` that breaks UTF-8 well-formedness, or `nil` if the whole
    /// buffer is valid UTF-8.
    public static func firstInvalidUTF8(_ bytes: [UInt8], backend: Backend = .fastest) -> Int? {
        let count = bytes.count
        guard count > 0 else { return nil }
        let index = bytes.withUnsafeBufferPointer { src -> Int in
            guard let base = src.baseAddress else { return count }
            return unsafe firstInvalidUTF8(base: base, count: count, backend: backend)
        }
        return index == count ? nil : index
    }

    // MARK: - Hamming distance (bit-vector similarity)

    /// The number of differing bits between `a[0..<count]` and `b[0..<count]` — `Σ popcount(a[i] ^ b[i])`,
    /// the KNN / sign-quantized-embedding similarity primitive. Exact integer; identical on every backend
    /// (NEON `cnt` / x86 `popcnt` / scalar). `.scalar` forces the portable reference.
    public static func hammingDistance(
        _ a: UnsafePointer<UInt8>,
        _ b: UnsafePointer<UInt8>,
        count: Int,
        backend: Backend = .fastest
    ) -> Int {
        guard count > 0 else { return 0 }
        if case .scalar = backend {
            return Int(unsafe adf_hamming_distance_scalar(a, b, count))
        }
        return Int(unsafe adf_hamming_distance(a, b, count))
    }

    /// Batched Hamming scan (the KNN-shortlist hot loop): writes the distance from `query` to each of
    /// `count` `width`-byte vectors packed contiguously in `corpus` into `out` (which must hold
    /// `count` values). One runtime dispatch for the whole scan; the query stays hot — this is where
    /// the SIMD win materializes at small (e.g. 64-byte) widths that a single-pair call cannot amortize.
    public static func hammingScan(
        query: UnsafePointer<UInt8>,
        corpus: UnsafePointer<UInt8>,
        width: Int,
        count: Int,
        into out: UnsafeMutablePointer<UInt32>
    ) {
        guard count > 0, width > 0 else { return }
        unsafe adf_hamming_scan(query, corpus, width, count, out)
    }

    // MARK: - First non-ASCII byte (ASCII-run skip)

    /// The offset within `base[0..<count]` of the first byte with the high bit set (`>= 0x80`), or
    /// `count` if every byte is ASCII — the ASCII-run skip an incremental UTF-8 validator uses before
    /// falling to per-scalar multi-byte checking.
    public static func firstNonASCII(
        base: UnsafePointer<UInt8>,
        count: Int,
        backend: Backend = .fastest
    ) -> Int {
        guard count > 0 else { return 0 }
        switch backend {
            case .fastest: return unsafe adf_index_of_nonascii(base, count)
            case .scalar: return unsafe adf_index_of_nonascii_scalar(base, count)
            case .sse2: return unsafe adf_index_of_nonascii_sse2(base, count)
            case .avx2: return unsafe adf_index_of_nonascii_avx2(base, count)
            case .neon: return unsafe adf_index_of_nonascii_neon(base, count)
        }
    }

    /// The index in `bytes` of the first non-ASCII byte (`>= 0x80`), or `nil` if the whole buffer is ASCII.
    public static func firstNonASCII(_ bytes: [UInt8], backend: Backend = .fastest) -> Int? {
        let count = bytes.count
        guard count > 0 else { return nil }
        let index = bytes.withUnsafeBufferPointer { src -> Int in
            guard let base = src.baseAddress else { return count }
            return unsafe firstNonASCII(base: base, count: count, backend: backend)
        }
        return index == count ? nil : index
    }
}

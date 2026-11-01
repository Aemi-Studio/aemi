//
//  AemiKernels+UTF8.swift
//  AemiKernels
//
//  The UTF-8 scans of the facade: full validation, and the first byte past an ASCII run. Moved out of
//  `AemiKernels.swift` to keep its type body under the metric limit; same kernels, same entry points.
//

internal import CAemiKernels

extension AemiKernels {
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
        @unsafe func scan(_ src: UnsafeBufferPointer<UInt8>) -> Int {
            guard let base = src.baseAddress else { return count }
            return unsafe firstInvalidUTF8(base: base, count: count, backend: backend)
        }
        let index = unsafe bytes.withUnsafeBufferPointer(scan)
        return index == count ? nil : index
    }

    /// The index of the first byte in `bytes` that breaks UTF-8 well-formedness, or `nil` if the whole
    /// buffer is valid UTF-8; the bytes are read in place, with no copy into an array.
    public static func firstInvalidUTF8(_ bytes: RawSpan, backend: Backend = .fastest) -> Int? {
        let count = bytes.byteCount
        guard count > 0 else { return nil }
        @unsafe func scan(_ src: UnsafeRawBufferPointer) -> Int {
            guard let base = src.baseAddress else { return count }
            return unsafe firstInvalidUTF8(
                base: base.assumingMemoryBound(to: UInt8.self),
                count: count,
                backend: backend
            )
        }
        let index = unsafe bytes.withUnsafeBytes(scan)
        return index == count ? nil : index
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
        @unsafe func scan(_ src: UnsafeBufferPointer<UInt8>) -> Int {
            guard let base = src.baseAddress else { return count }
            return unsafe firstNonASCII(base: base, count: count, backend: backend)
        }
        let index = unsafe bytes.withUnsafeBufferPointer(scan)
        return index == count ? nil : index
    }

    /// The index in `bytes` of the first non-ASCII byte (`>= 0x80`), or `nil` if the whole buffer is
    /// ASCII; the bytes are read in place, with no copy into an array.
    public static func firstNonASCII(_ bytes: RawSpan, backend: Backend = .fastest) -> Int? {
        let count = bytes.byteCount
        guard count > 0 else { return nil }
        @unsafe func scan(_ src: UnsafeRawBufferPointer) -> Int {
            guard let base = src.baseAddress else { return count }
            return unsafe firstNonASCII(base: base.assumingMemoryBound(to: UInt8.self), count: count, backend: backend)
        }
        let index = unsafe bytes.withUnsafeBytes(scan)
        return index == count ? nil : index
    }
}

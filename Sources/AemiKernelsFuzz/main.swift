// libFuzzer entry point for the AemiKernels SIMD byte kernels. Built only when `AEMI_FUZZ` is set (see
// `Package.swift`), with `-parse-as-library -sanitize=fuzzer`. `-sanitize=fuzzer` is a Linux capability
// of the Swift toolchain (the Darwin SDK rejects it), so this target is built and run in the Linux CI
// fuzz job — where `.avx2` / `.sse2` (x86-64) and NEON (aarch64) exercise the REAL wide kernels that
// Rosetta cannot on a Mac. Pair with `,address` to make an over-read a crash.
//
// The contract under test, for ANY byte string and ANY parameters:
//   • DIFFERENTIAL: every backend (`.fastest`, `.sse2`, `.avx2`, `.neon`) agrees with `.scalar`.
//   • INVARIANT: each find-first result is in `0...count`; the byte at the result satisfies the kernel's
//     predicate; no earlier byte does.
// A divergence, a broken invariant, or an out-of-bounds read is a crash the fuzzer flags as a finding.

import AemiKernels

private func requireEqual(_ lhs: Int, _ rhs: Int, _ label: StaticString) {
    precondition(lhs == rhs, "backend divergence: \(label) gave \(lhs), scalar \(rhs)")
}

/// Assert the find-first invariants for one kernel result against its predicate.
private func requireInvariants(
    _ result: Int, _ buffer: UnsafeBufferPointer<UInt8>, _ label: StaticString,
    _ predicate: (UInt8) -> Bool
) {
    precondition(result >= 0 && result <= buffer.count, "\(label): result \(result) out of range")
    if result < buffer.count {
        precondition(predicate(buffer[result]), "\(label): byte at result fails predicate")
    }
    for index in 0 ..< result where predicate(buffer[index]) {
        preconditionFailure("\(label): an earlier byte satisfies the predicate")
    }
}

// The libFuzzer entry point is a single C-ABI function by construction: it derives every kernel
// parameter from one input buffer and then drives each kernel in turn. Splitting it would only
// scatter that one linear script. Unshipped (AEMI_FUZZ-gated, Linux-CI only).
@_cdecl("LLVMFuzzerTestOneInput")
// swiftlint:disable:next function_body_length
public func LLVMFuzzerTestOneInput(_ start: UnsafePointer<UInt8>?, _ count: Int) -> CInt {
    guard let start, count > 0 else { return 0 }

    // Steer the kernel parameters from an 8-byte prefix so the fuzzer can drive quote/escape/needles/
    // min/tab; the remainder is the buffer under test. Short inputs use defaults + the whole buffer.
    let quote: UInt8
    let escape: UInt8
    let needle: UInt8
    let minAllowed: UInt8
    let n0: UInt8
    let n1: UInt8
    let n2: UInt8
    let n3: UInt8
    let n4: UInt8
    let allowTab: Bool
    let bufferBase: UnsafePointer<UInt8>
    let bufferCount: Int
    if count >= 8 {
        quote = start[0]
        escape = start[1]
        n0 = start[2]
        n1 = start[3]
        n2 = start[4]
        n3 = start[5]
        n4 = start[6]
        minAllowed = start[7]
        needle = start[2]
        allowTab = (start[0] & 1) == 1
        bufferBase = start + 8
        bufferCount = count - 8
    } else {
        quote = 0x22
        escape = 0x5C
        needle = 0x2C
        minAllowed = 0x20
        n0 = 0x26
        n1 = 0x3C
        n2 = 0x3E
        n3 = 0x22
        n4 = 0x27
        allowTab = true
        bufferBase = start
        bufferCount = count
    }
    let buffer = UnsafeBufferPointer(start: bufferBase, count: bufferCount)
    let base = bufferBase
    let n = bufferCount

    // indexOfStringStop — full backend fan-out (exposes sse2/avx2/neon).
    let stopScalar = AemiKernels.indexOfStringStop(
        base: base, count: n, quote: quote, escape: escape, backend: .scalar)
    for backend in [AemiKernels.Backend.fastest, .sse2, .avx2, .neon] {
        requireEqual(
            AemiKernels.indexOfStringStop(
                base: base, count: n, quote: quote, escape: escape, backend: backend),
            stopScalar, "indexOfStringStop")
    }
    requireInvariants(stopScalar, buffer, "indexOfStringStop") {
        $0 < 0x20 || $0 >= 0x80 || $0 == quote || $0 == escape
    }

    // firstNonASCII — full backend fan-out.
    let nonAsciiScalar = AemiKernels.firstNonASCII(base: base, count: n, backend: .scalar)
    for backend in [AemiKernels.Backend.fastest, .sse2, .avx2, .neon] {
        requireEqual(
            AemiKernels.firstNonASCII(base: base, count: n, backend: backend),
            nonAsciiScalar, "firstNonASCII")
    }
    requireInvariants(nonAsciiScalar, buffer, "firstNonASCII") { $0 >= 0x80 }

    // firstIndexOfByte.
    let byteScalar = AemiKernels.firstIndexOfByte(base: base, count: n, needle: needle, backend: .scalar)
    requireEqual(
        AemiKernels.firstIndexOfByte(base: base, count: n, needle: needle, backend: .fastest),
        byteScalar, "firstIndexOfByte")
    requireInvariants(byteScalar, buffer, "firstIndexOfByte") { $0 == needle }

    // firstIndexOfAny.
    let anyScalar = AemiKernels.firstIndexOfAny(base: base, count: n, n0, n1, n2, n3, n4, backend: .scalar)
    requireEqual(
        AemiKernels.firstIndexOfAny(base: base, count: n, n0, n1, n2, n3, n4, backend: .fastest),
        anyScalar, "firstIndexOfAny")
    requireInvariants(anyScalar, buffer, "firstIndexOfAny") {
        $0 == n0 || $0 == n1 || $0 == n2 || $0 == n3 || $0 == n4
    }

    // indexOfControlOrAny.
    let ctrlAnyScalar = AemiKernels.indexOfControlOrAny(
        base: base, count: n, n0, n1, n2, n3, n4, backend: .scalar)
    requireEqual(
        AemiKernels.indexOfControlOrAny(base: base, count: n, n0, n1, n2, n3, n4, backend: .fastest),
        ctrlAnyScalar, "indexOfControlOrAny")
    requireInvariants(ctrlAnyScalar, buffer, "indexOfControlOrAny") {
        $0 < 0x20 || $0 == n0 || $0 == n1 || $0 == n2 || $0 == n3 || $0 == n4
    }

    // firstDisallowedText.
    let textScalar = AemiKernels.firstDisallowedText(
        base: base, count: n, minAllowed: minAllowed, allowTab: allowTab, backend: .scalar)
    requireEqual(
        AemiKernels.firstDisallowedText(
            base: base, count: n, minAllowed: minAllowed, allowTab: allowTab, backend: .fastest),
        textScalar, "firstDisallowedText")
    requireInvariants(textScalar, buffer, "firstDisallowedText") {
        $0 < 0x80 && ($0 == 0x7F || ($0 < minAllowed && !(allowTab && $0 == 0x09)))
    }

    // firstInvalidUTF8 — SIMD (SSE/AVX2 on x86, NEON on arm64) vs scalar oracle, + range invariant.
    let utf8Scalar = AemiKernels.firstInvalidUTF8(base: base, count: n, backend: .scalar)
    requireEqual(
        AemiKernels.firstInvalidUTF8(base: base, count: n, backend: .fastest), utf8Scalar,
        "firstInvalidUTF8")
    precondition(utf8Scalar >= 0 && utf8Scalar <= n, "firstInvalidUTF8: result out of range")

    // foldASCII (transform) — every backend must equal the scalar backend.
    let bytes = [UInt8](buffer)
    let foldScalar = AemiKernels.foldedASCII(bytes, backend: .scalar)
    for backend in [AemiKernels.Backend.fastest, .sse2, .avx2, .neon] {
        precondition(
            AemiKernels.foldedASCII(bytes, backend: backend) == foldScalar,
            "foldASCII backend divergence")
    }

    return 0
}

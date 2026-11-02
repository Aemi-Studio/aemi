//
//  AemiKernels+Hex.swift
//  AemiKernels
//
//  The hex kernels behind `AemiKernel.Hex`'s bulk encode and decode. `package` API over buffers: every entry point checks the
//  buffers against the kernel's contract with a `precondition` (output room, no overlap) and the kernel's answer against what it
//  may return, so a wrong size traps instead of reading or writing out of bounds.
//

internal import CAemiKernels

extension AemiKernels {
    /// Writes the two digits of each byte of `input` (high nibble first) to the front of `output`.
    ///
    /// - Precondition: `output.count >= 2 * input.count`; `input` and `output` do not overlap.
    package static func hexEncode(
        input: UnsafeBufferPointer<UInt8>,
        output: UnsafeMutableBufferPointer<UInt8>,
        uppercase: Bool,
        backend: Backend = .fastest
    ) {
        let (needed, overflow) = input.count.multipliedReportingOverflow(by: 2)
        precondition(!overflow && output.count >= needed, "the hex output cannot hold two digits per byte")
        guard input.count > 0, let source = input.baseAddress, let target = output.baseAddress else { return }
        let shared = unsafe overlaps(source, input.count, UnsafePointer(target), output.count)
        precondition(!shared, "hex input and output overlap")
        switch backend {
            case .scalar: unsafe adf_hex_encode_scalar(source, input.count, target, uppercase ? 1 : 0)
            case .sse2, .avx2:
                unsafe adf_hex_encode_avx2(source, input.count, target, uppercase ? 1 : 0)
            case .fastest, .neon: unsafe adf_hex_encode(source, input.count, target, uppercase ? 1 : 0)
        }
    }

    /// Decodes the digit pairs of `input` (either case) into the front of `output`, up to the first pair holding a byte that is
    /// not a hex digit, and returns 2 times the number of pairs decoded.
    ///
    /// - Precondition: `output.count >= input.count / 2`; `input` and `output` do not overlap.
    package static func hexDecode(
        input: UnsafeBufferPointer<UInt8>,
        output: UnsafeMutableBufferPointer<UInt8>,
        backend: Backend = .fastest
    ) -> Int {
        precondition(output.count >= input.count / 2, "the hex output cannot hold the bytes of the input")
        guard input.count > 1, let source = input.baseAddress, let target = output.baseAddress else { return 0 }
        let shared = unsafe overlaps(source, input.count, UnsafePointer(target), output.count)
        precondition(!shared, "hex input and output overlap")
        let consumed: Int
        switch backend {
            case .scalar: consumed = Int(unsafe adf_hex_decode_scalar(source, input.count, target))
            case .sse2, .avx2: consumed = Int(unsafe adf_hex_decode_avx2(source, input.count, target))
            case .fastest, .neon: consumed = Int(unsafe adf_hex_decode(source, input.count, target))
        }
        precondition(
            consumed >= 0 && consumed <= input.count && consumed % 2 == 0,
            "the hex decode kernel returned \(consumed) for \(input.count) digits"
        )
        return consumed
    }
}

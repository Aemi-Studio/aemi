//
//  AemiKernels+Base64.swift
//  AemiKernels
//
//  The block kernels behind `AemiKernel.Base64`: whole blocks to symbols, and whole blocks back. They do no policy: padding,
//  tails, line wrapping, error offsets and every option stay with the caller.
//
//  These are `package` API, not public: the contract is tight (the output must hold what the kernel may write, the tables
//  must be exactly 64 and 256 bytes) and the only caller is `Base64`. Even so, every entry point checks its buffers against
//  the contract with a `precondition`, so a wrong size traps instead of reading or writing out of bounds, and checks the
//  kernel's answer against what it may legally return.
//

internal import CAemiKernels

extension AemiKernels {
    /// Encodes whole blocks of `input` through `table` (64 symbols, indexed by sextet value) into the front of `output` and
    /// returns the number of input bytes consumed (a multiple of 3, at most `input.count`). `output` is written for
    /// `consumed / 3 * 4` bytes and no further.
    ///
    /// `tail` is `plus | slash << 8` for an alphabet `A-Za-z0-9` + two symbols, else 0 (x86-64 computes symbols and needs it;
    /// arm64 looks them up and ignores it).
    ///
    /// - Precondition: `table.count == 64`; `output.count >= input.count / 3 * 4`; `input` and `output` do not overlap.
    package static func base64EncodeBlocks(
        table: UnsafeBufferPointer<UInt8>,
        tail: UInt16,
        input: UnsafeBufferPointer<UInt8>,
        output: UnsafeMutableBufferPointer<UInt8>,
        backend: Backend = .fastest
    ) -> Int {
        precondition(table.count == 64, "the Base64 symbol table must have 64 entries")
        precondition(output.count >= input.count / 3 * 4, "the Base64 output cannot hold the symbols of the input")
        guard input.count > 0, let tablePointer = table.baseAddress, let source = input.baseAddress,
            let target = output.baseAddress
        else { return 0 }
        let shared = unsafe overlaps(source, input.count, UnsafePointer(target), output.count)
        precondition(!shared, "Base64 input and output overlap")
        let consumed: Int
        if case .scalar = backend {
            consumed = Int(unsafe adf_b64_encode_blocks_scalar(tablePointer, source, input.count, target))
        } else {
            consumed = Int(unsafe adf_b64_encode_blocks(tablePointer, tail, source, input.count, target))
        }
        precondition(
            consumed >= 0 && consumed <= input.count && consumed % 3 == 0,
            "the Base64 encode kernel returned \(consumed) for \(input.count) bytes"
        )
        return consumed
    }

    /// Decodes whole blocks of `input` through `lookup` (256 bytes: a byte's sextet, or 0xFF for a byte outside the alphabet)
    /// into the front of `output`, stopping before the first block holding such a byte, and returns the number of symbols
    /// consumed (a multiple of 4, at most `input.count`). `output` is written for `consumed / 4 * 3` bytes and no further.
    ///
    /// - Precondition: `lookup.count == 256`; `output.count >= input.count / 4 * 3`; `input` and `output` do not overlap.
    package static func base64DecodeBlocks(
        lookup: UnsafeBufferPointer<UInt8>,
        tail: UInt16,
        input: UnsafeBufferPointer<UInt8>,
        output: UnsafeMutableBufferPointer<UInt8>,
        backend: Backend = .fastest
    ) -> Int {
        precondition(lookup.count == 256, "the Base64 reverse table must have 256 entries")
        precondition(output.count >= input.count / 4 * 3, "the Base64 output cannot hold the bytes of the input")
        guard input.count > 0, let tablePointer = lookup.baseAddress, let source = input.baseAddress,
            let target = output.baseAddress
        else { return 0 }
        let shared = unsafe overlaps(source, input.count, UnsafePointer(target), output.count)
        precondition(!shared, "Base64 input and output overlap")
        let consumed: Int
        if case .scalar = backend {
            consumed = Int(unsafe adf_b64_decode_blocks_scalar(tablePointer, source, input.count, target))
        } else {
            consumed = Int(unsafe adf_b64_decode_blocks(tablePointer, tail, source, input.count, target))
        }
        precondition(
            consumed >= 0 && consumed <= input.count && consumed % 4 == 0,
            "the Base64 decode kernel returned \(consumed) for \(input.count) symbols"
        )
        return consumed
    }

    /// Whether `a[0..<aCount]` and `b[0..<bCount]` share a byte.
    static func overlaps(
        _ a: UnsafePointer<UInt8>,
        _ aCount: Int,
        _ b: UnsafePointer<UInt8>,
        _ bCount: Int
    ) -> Bool {
        guard aCount > 0, bCount > 0 else { return false }
        let aStart = UInt(bitPattern: a)
        let bStart = UInt(bitPattern: b)
        return aStart < bStart &+ UInt(bCount) && bStart < aStart &+ UInt(aCount)
    }
}

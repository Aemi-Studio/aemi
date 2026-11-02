//
//  AemiKernels+Percent.swift
//  AemiKernels
//
//  The percent-coding kernels behind `AemiKernel.PercentCoding`. `package` API over buffers: each entry point checks the buffers
//  against the kernel's contract with a `precondition` and the kernel's answer against what it may return.
//

internal import CAemiKernels

extension AemiKernels {
    /// How many bytes of `input` are in `set`.
    package static func count(inSet set: ByteSet, in input: UnsafeBufferPointer<UInt8>) -> Int {
        guard input.count > 0, let base = input.baseAddress else { return 0 }
        let count = unsafe set.withTables { low, high in Int(unsafe adf_count_in_set(base, input.count, low, high)) }
        precondition(count >= 0 && count <= input.count, "the set count kernel returned \(count) for \(input.count)")
        return count
    }

    /// Copies `input` to `output` with each byte of `escaping` written as `%XY` (uppercase hex).
    ///
    /// - Precondition: `output.count == input.count + 2 * count(inSet: escaping, in: input)`; no overlap.
    package static func percentEncode(
        _ input: UnsafeBufferPointer<UInt8>,
        escaping set: ByteSet,
        into output: UnsafeMutableBufferPointer<UInt8>
    ) {
        guard input.count > 0, let source = input.baseAddress, let target = output.baseAddress else {
            precondition(output.count == input.count, "percentEncode: the output is not the encoded length")
            return
        }
        let shared = unsafe overlaps(source, input.count, UnsafePointer(target), output.count)
        precondition(!shared, "percent-coding input and output overlap")
        let written = unsafe set.withTables { low, high in
            unsafe adf_percent_encode(source, input.count, low, high, target, output.count)
        }
        // The kernel writes nothing past `output.count`; SIZE_MAX (or any other answer) means the size was wrong.
        precondition(written == output.count, "percentEncode: the output is not the encoded length")
    }

    /// Decodes `input` into the front of `output` (`%XY` in either case to its byte, `+` to a space when `plusAsSpace`) and
    /// returns the bytes written, or `nil` with nothing promised about `output` when a `%` is not followed by two hex digits.
    ///
    /// - Precondition: `output.count >= input.count`; no overlap.
    package static func percentDecode(
        _ input: UnsafeBufferPointer<UInt8>,
        into output: UnsafeMutableBufferPointer<UInt8>,
        plusAsSpace: Bool
    ) -> Int? {
        precondition(output.count >= input.count, "percentDecode: the output is shorter than the input")
        guard input.count > 0, let source = input.baseAddress, let target = output.baseAddress else { return 0 }
        let shared = unsafe overlaps(source, input.count, UnsafePointer(target), output.count)
        precondition(!shared, "percent-coding input and output overlap")
        var bad = 0
        let written = unsafe adf_percent_decode(source, input.count, target, plusAsSpace ? 1 : 0, &bad)
        if written == -1 { return nil }  // SIZE_MAX: a malformed escape at `bad`
        precondition(written >= 0 && written <= input.count, "percentDecode returned \(written) for \(input.count)")
        return written
    }
}

extension AemiKernels.ByteSet {
    /// Calls `body` with the two 16-byte nibble tables.
    func withTables<R>(_ body: (UnsafePointer<UInt8>, UnsafePointer<UInt8>) -> R) -> R {
        var low = self.low
        var high = self.high
        return withUnsafeBytes(of: &low) { lowBytes in
            withUnsafeBytes(of: &high) { highBytes in
                // SAFETY: each table is 16 bytes, which is what the kernels read from each pointer.
                let lowPointer = unsafe lowBytes.baseAddress!.assumingMemoryBound(to: UInt8.self)
                let highPointer = unsafe highBytes.baseAddress!.assumingMemoryBound(to: UInt8.self)
                return unsafe body(lowPointer, highPointer)
            }
        }
    }
}

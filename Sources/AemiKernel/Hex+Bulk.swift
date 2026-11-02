internal import AemiKernels

// Bulk hexadecimal: whole buffers to digits and back, on the SIMD kernels of `AemiKernels` for contiguous input (NEON on arm64,
// AVX2 or SSSE3 on x86-64). Any other `Collection` is copied once first. Errors are reported by offset, the same on every ISA:
// the kernels decode only up to the first bad pair, and the byte that is wrong is found here.
extension Hex {
    /// Why a decode failed.
    public enum DecodeError: Error, Sendable, Hashable {
        /// A byte that is not a hex digit (`0-9`, `a-f`, `A-F`), at this offset of the input. The first such byte is reported.
        case invalidByte(UInt8, offset: Int)
        /// Every byte is a digit, but there is an odd number of them.
        case oddLength(Int)
        /// The output buffer holds fewer than the `required` bytes.
        case outputBufferTooSmall(required: Int)
    }

    /// Why an encode into a caller's buffer failed.
    public enum EncodeError: Error, Sendable, Hashable {
        /// The output buffer holds fewer than the `required` bytes.
        case outputBufferTooSmall(required: Int)
        /// The encoded length (twice the input) would overflow `Int`.
        case inputTooLarge
    }

    // MARK: - Encode

    /// The two digits of each byte, high nibble first: `[0xAB, 0x01]` is `"ab01"` (`"AB01"` when `uppercase`).
    ///
    /// - Complexity: O(n).
    public static func encode(_ bytes: some Collection<UInt8>, uppercase: Bool = false) -> [UInt8] {
        let (total, overflow) = bytes.count.multipliedReportingOverflow(by: 2)
        precondition(!overflow, "Hex: the encoded length overflows Int")
        return unsafe [UInt8](unsafeUninitializedCapacity: total) { buffer, initialized in
            initialized = 0
            unsafe withContiguous(bytes) {
                unsafe AemiKernels.hexEncode(input: $0, output: buffer, uppercase: uppercase)
            }
            initialized = total
        }
    }

    /// The digits of `bytes` as a `String`. See ``encode(_:uppercase:)``.
    public static func encodedString(_ bytes: some Collection<UInt8>, uppercase: Bool = false) -> String {
        String(decoding: encode(bytes, uppercase: uppercase), as: UTF8.self)
    }

    /// Writes the digits of `bytes` to the front of `output` and returns their count (`2 * bytes.count`); nothing is allocated.
    ///
    /// - Throws: ``EncodeError/outputBufferTooSmall(required:)`` when `output` is too small; nothing is written then.
    public static func encode(
        _ bytes: some Collection<UInt8>,
        into output: UnsafeMutableBufferPointer<UInt8>,
        uppercase: Bool = false
    ) throws(EncodeError) -> Int {
        let (total, overflow) = bytes.count.multipliedReportingOverflow(by: 2)
        guard !overflow else { throw .inputTooLarge }
        guard total <= output.count else { throw .outputBufferTooSmall(required: total) }
        unsafe withContiguous(bytes) {
            unsafe AemiKernels.hexEncode(
                input: $0,
                output: UnsafeMutableBufferPointer(rebasing: output[..<total]),
                uppercase: uppercase
            )
        }
        return total
    }

    // MARK: - Decode

    /// The bytes spelled by the digit pairs of `text` (either case). Strict: no prefix, no whitespace, an even count.
    ///
    /// - Throws: ``DecodeError/invalidByte(_:offset:)`` for the first byte that is not a digit, else
    ///   ``DecodeError/oddLength(_:)``.
    public static func decode(_ text: some Collection<UInt8>) throws(DecodeError) -> [UInt8] {
        let total = text.count / 2
        var failure: DecodeError?
        let bytes = unsafe [UInt8](unsafeUninitializedCapacity: total) { buffer, initialized in
            initialized = 0
            failure = unsafe withContiguous(text) { unsafe decodeContiguous($0, into: buffer) }
            if failure == nil { initialized = total }
        }
        if let failure { throw failure }
        return bytes
    }

    /// The bytes spelled by the digits of `text`. See the collection overload.
    public static func decode(_ text: some StringProtocol) throws(DecodeError) -> [UInt8] {
        try decode(text.utf8)
    }

    /// Decodes the digits of `text` into the front of `output` and returns the number of bytes written; nothing is allocated.
    ///
    /// - Throws: as the allocating `decode`, and ``DecodeError/outputBufferTooSmall(required:)`` when `output`
    ///   holds fewer than `text.count / 2` bytes (checked first; nothing is written then).
    public static func decode(
        _ text: some Collection<UInt8>,
        into output: UnsafeMutableBufferPointer<UInt8>
    ) throws(DecodeError) -> Int {
        let total = text.count / 2
        guard total <= output.count else { throw .outputBufferTooSmall(required: total) }
        let target = unsafe UnsafeMutableBufferPointer(rebasing: output[..<total])
        if let failure = unsafe withContiguous(text, { unsafe decodeContiguous($0, into: target) }) { throw failure }
        return total
    }

    // MARK: - Plumbing

    /// Decodes all of `input` into `out` (exactly `input.count / 2` bytes), or returns the error.
    private static func decodeContiguous(
        _ input: UnsafeBufferPointer<UInt8>,
        into out: UnsafeMutableBufferPointer<UInt8>
    ) -> DecodeError? {
        let consumed = unsafe AemiKernels.hexDecode(input: input, output: out)
        let count = input.count
        if consumed < count / 2 * 2 {
            // The pair at `consumed` holds the first byte that is not a digit.
            let high = unsafe input[consumed]
            if value(high) == nil { return .invalidByte(high, offset: consumed) }
            return .invalidByte(unsafe input[consumed + 1], offset: consumed + 1)
        }
        if count % 2 == 1 {
            let last = unsafe input[count - 1]
            return value(last) == nil ? .invalidByte(last, offset: count - 1) : .oddLength(count)
        }
        return nil
    }

    /// Calls `body` with the bytes of `collection` in contiguous memory: in place when it has such storage, else a copy.
    private static func withContiguous<R>(
        _ collection: some Collection<UInt8>,
        _ body: (UnsafeBufferPointer<UInt8>) -> R
    ) -> R {
        if let result = collection.withContiguousStorageIfAvailable(body) { return result }
        let copy = ContiguousArray(collection)
        return copy.withUnsafeBufferPointer(body)
    }
}

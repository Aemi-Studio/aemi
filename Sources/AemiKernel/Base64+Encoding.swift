// Configurable encoding. The `Alphabet`/`padding:` overloads stay in `Base64.swift` and delegate here.
extension Base64 {
    /// Encodes `bytes` under `options`: the alphabet, `=` padding (written unless
    /// ``PaddingPolicy/forbidden``), and optional line wrapping at ``Options/lineLength`` with
    /// ``Options/lineEnding`` between lines (none after the last line).
    ///
    /// Contiguous input is encoded in place with a single allocation for the result; any other
    /// `Collection` is first copied into an array.
    ///
    /// - Complexity: O(n) in the input length.
    public static func encode(_ bytes: some Collection<UInt8>, options: Options) -> [UInt8] {
        let total = requiredLength(forByteCount: bytes.count, options: options)
        return unsafe [UInt8](unsafeUninitializedCapacity: total) { buffer, initialized in
            initialized = 0
            initialized = unsafe encodeCollection(bytes, into: buffer, options: options)
        }
    }

    /// Encodes `bytes` under `options`. See ``encode(_:options:)``.
    public static func encode(_ bytes: Span<UInt8>, options: Options) -> [UInt8] {
        let total = requiredLength(forByteCount: bytes.count, options: options)
        return unsafe [UInt8](unsafeUninitializedCapacity: total) { buffer, initialized in
            initialized = 0
            initialized = bytes.withUnsafeBufferPointer {
                unsafe encodeContiguous($0, into: buffer, options: options)
            }
        }
    }

    /// Encodes `bytes` under `options` as a `String` (the encoding is always ASCII).
    public static func encodedString(_ bytes: some Collection<UInt8>, options: Options) -> String {
        String(decoding: encode(bytes, options: options), as: UTF8.self)
    }

    /// Encodes `bytes` into the front of `output` and returns the number of bytes written; no memory is
    /// allocated. Size `output` with ``Options/encodedLength(forByteCount:)``.
    ///
    /// - Throws: ``EncodeError/outputBufferTooSmall(required:)`` if `output` is too small; nothing is
    ///   written then.
    public static func encode(
        _ bytes: some Collection<UInt8>, into output: inout MutableSpan<UInt8>, options: Options
    ) throws(EncodeError) -> Int {
        let capacity = output.count
        let total = try checkedLength(forByteCount: bytes.count, capacity: capacity, options: options)
        return output.withUnsafeMutableBufferPointer { buffer in
            let target = unsafe UnsafeMutableBufferPointer(rebasing: buffer[..<total])
            return unsafe encodeCollection(bytes, into: target, options: options)
        }
    }

    /// Encodes `bytes` into `output` like ``encode(_:into:options:)``, for callers that hold a buffer
    /// pointer (`Array.withUnsafeMutableBufferPointer`) rather than a `MutableSpan`.
    public static func encode(
        _ bytes: some Collection<UInt8>, into output: UnsafeMutableBufferPointer<UInt8>, options: Options
    ) throws(EncodeError) -> Int {
        let total = try checkedLength(forByteCount: bytes.count, capacity: output.count, options: options)
        let target = unsafe UnsafeMutableBufferPointer(rebasing: output[..<total])
        return unsafe encodeCollection(bytes, into: target, options: options)
    }

    /// Encodes `bytes` into the front of `output`. See ``encode(_:into:options:)``.
    public static func encode(
        _ bytes: Span<UInt8>, into output: inout MutableSpan<UInt8>, options: Options
    ) throws(EncodeError) -> Int {
        let total = try checkedLength(forByteCount: bytes.count, capacity: output.count, options: options)
        return output.withUnsafeMutableBufferPointer { buffer in
            let target = unsafe UnsafeMutableBufferPointer(rebasing: buffer[..<total])
            return bytes.withUnsafeBufferPointer { unsafe encodeContiguous($0, into: target, options: options) }
        }
    }

    // MARK: - Plumbing

    /// The encoded size, for sizing the result array. Overflow needs an input of 2^62 bytes, more than
    /// any address space holds, so it is a programmer error rather than a runtime condition.
    private static func requiredLength(forByteCount count: Int, options: Options) -> Int {
        guard let total = options.encodedLength(forByteCount: count) else {
            preconditionFailure("Base64: encoded length overflows Int")
        }
        return total
    }

    private static func checkedLength(
        forByteCount count: Int, capacity: Int, options: Options
    ) throws(EncodeError) -> Int {
        guard let total = options.encodedLength(forByteCount: count) else { throw .inputTooLarge }
        guard total <= capacity else { throw .outputBufferTooSmall(required: total) }
        return total
    }

    /// Encodes into `out`, which holds exactly the encoded length. Returns that length.
    private static func encodeCollection(
        _ bytes: some Collection<UInt8>, into out: UnsafeMutableBufferPointer<UInt8>, options: Options
    ) -> Int {
        let done = bytes.withContiguousStorageIfAvailable {
            unsafe encodeContiguous($0, into: out, options: options)
        }
        if let done { return done }
        // A non-contiguous collection is copied once; the encoder needs random access.
        let copy = ContiguousArray(bytes)
        return copy.withUnsafeBufferPointer { unsafe encodeContiguous($0, into: out, options: options) }
    }

    private static func encodeContiguous(
        _ input: UnsafeBufferPointer<UInt8>, into out: UnsafeMutableBufferPointer<UInt8>, options: Options
    ) -> Int {
        let total = out.count
        let symbols = symbolCount(forByteCount: input.count, padded: options.writesPadding)
        // Symbols go to the END of the buffer; wrapping then moves each line forward over the gap and
        // writes the separator after it, so wrapping needs no second buffer.
        let start = total - symbols
        options.alphabet.encodeTable.withUnsafeBufferPointer { table in
            unsafe writeSymbols(of: input, to: out, at: start, table: table, padded: options.writesPadding)
        }
        if let width = options.effectiveLineLength, symbols > 0 {
            unsafe wrapLines(in: out, from: start, symbols: symbols, width: width, ending: options.lineEnding)
        }
        return total
    }

    private static func symbolCount(forByteCount count: Int, padded: Bool) -> Int {
        let remainder = count % 3
        return count / 3 * 4 + (remainder == 0 ? 0 : (padded ? 4 : remainder + 1))
    }

    private static func writeSymbols(
        of input: UnsafeBufferPointer<UInt8>, to out: UnsafeMutableBufferPointer<UInt8>, at start: Int,
        table: UnsafeBufferPointer<UInt8>, padded: Bool
    ) {
        var source = 0
        var target = start
        let end = input.count
        while end - source >= 3 {
            let chunk =
                (UInt32(unsafe input[source]) << 16) | (UInt32(unsafe input[source + 1]) << 8)
                | UInt32(unsafe input[source + 2])
            unsafe out[target] = unsafe table[Int(chunk >> 18)]
            unsafe out[target + 1] = unsafe table[Int((chunk >> 12) & 0x3F)]
            unsafe out[target + 2] = unsafe table[Int((chunk >> 6) & 0x3F)]
            unsafe out[target + 3] = unsafe table[Int(chunk & 0x3F)]
            source += 3
            target += 4
        }
        let remainder = end - source
        guard remainder > 0 else { return }
        var chunk = UInt32(unsafe input[source]) << 16
        if remainder == 2 { chunk |= UInt32(unsafe input[source + 1]) << 8 }
        unsafe out[target] = unsafe table[Int(chunk >> 18)]
        unsafe out[target + 1] = unsafe table[Int((chunk >> 12) & 0x3F)]
        target += 2
        if remainder == 2 {
            unsafe out[target] = unsafe table[Int((chunk >> 6) & 0x3F)]
            target += 1
        }
        if padded {
            unsafe out[target] = Base64.padByte
            if remainder == 1 { unsafe out[target + 1] = Base64.padByte }
        }
    }

    /// Moves the `symbols` bytes at `start...` to the front of `out`, `width` per line, writing `ending`
    /// between lines. A line is always moved before the separator after it is written, and the gap
    /// between read and write positions never shrinks below the separators still to come, so no unread
    /// symbol is overwritten.
    private static func wrapLines(
        in out: UnsafeMutableBufferPointer<UInt8>, from start: Int, symbols: Int, width: Int,
        ending: LineEnding
    ) {
        guard let base = out.baseAddress else { return }
        var read = start
        var write = 0
        var remaining = symbols
        while remaining > 0 {
            let run = Swift.min(width, remaining)
            if read != write { unsafe (base + write).update(from: base + read, count: run) }
            read += run
            write += run
            remaining -= run
            guard remaining > 0 else { break }
            if ending == .crlf {
                unsafe base[write] = 0x0D
                write += 1
            }
            unsafe base[write] = 0x0A
            write += 1
        }
    }
}

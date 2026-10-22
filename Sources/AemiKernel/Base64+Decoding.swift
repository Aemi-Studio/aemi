// Configurable decoding. The nil-returning `decode(_:alphabet:)` stays in `Base64.swift`; everything
// here reports why a decode failed.
extension Base64 {
    /// Decodes `input` under `options`.
    ///
    /// Contiguous input (`Array`, `ArraySlice`, a native `String.utf8`, …) takes a table-driven fast
    /// path; any other `Collection` is decoded byte by byte with the same rules. Nothing is allocated
    /// but the result.
    ///
    /// - Parameters:
    ///   - input: The encoded text as bytes.
    ///   - options: The strictness and format. Use ``Options/strict`` for signature-bearing or other
    ///     security-relevant text.
    /// - Returns: The decoded bytes.
    /// - Throws: ``DecodeError`` describing the first problem found, in input order.
    /// - Complexity: O(n) in the input length.
    public static func decode(
        _ input: some Collection<UInt8>, options: Options
    ) throws(DecodeError) -> [UInt8] {
        let capacity = outputCapacity(forInputCount: input.count, options: options)
        do {
            return try unsafe [UInt8](unsafeUninitializedCapacity: capacity) {
                (buffer, initialized) throws(DecodeError) in
                initialized = 0
                initialized = try unsafe decodeCollection(input, into: buffer, options: options)
            }
        } catch {
            throw report(error, options)
        }
    }

    /// Decodes the UTF-8 bytes of `string` under `options`. See ``decode(_:options:)``.
    public static func decode(
        _ string: some StringProtocol, options: Options
    ) throws(DecodeError) -> [UInt8] {
        try decode(string.utf8, options: options)
    }

    /// Decodes `input` under `options`. See ``decode(_:options:)``.
    public static func decode(_ input: Span<UInt8>, options: Options) throws(DecodeError) -> [UInt8] {
        let capacity = outputCapacity(forInputCount: input.count, options: options)
        do {
            return try unsafe [UInt8](unsafeUninitializedCapacity: capacity) {
                (buffer, initialized) throws(DecodeError) in
                initialized = 0
                initialized = try unsafe decodeSpan(input, into: buffer, options: options)
            }
        } catch {
            throw report(error, options)
        }
    }

    /// Decodes `input` into the front of `output` and returns the number of bytes written; no memory is
    /// allocated. Size `output` with ``Options/maximumDecodedLength(forEncodedCount:)``.
    ///
    /// - Throws: ``DecodeError``, including ``DecodeError/outputBufferTooSmall`` when the decoded bytes
    ///   do not fit. Nothing is ever written past `output`. After a throw the contents of `output` are
    ///   unspecified; do not use them.
    public static func decode(
        _ input: some Collection<UInt8>, into output: inout MutableSpan<UInt8>, options: Options
    ) throws(DecodeError) -> Int {
        try output.withUnsafeMutableBufferPointer { (buffer) throws(DecodeError) in
            try unsafe decode(input, into: buffer, options: options)
        }
    }

    /// Decodes `input` into `output` like ``decode(_:into:options:)``, for callers that hold a buffer
    /// pointer (`Array.withUnsafeMutableBufferPointer`) rather than a `MutableSpan`, which needs a newer
    /// OS to create from an array. The pointer is used only for this call.
    public static func decode(
        _ input: some Collection<UInt8>, into output: UnsafeMutableBufferPointer<UInt8>, options: Options
    ) throws(DecodeError) -> Int {
        do {
            return try unsafe decodeCollection(input, into: output, options: options)
        } catch {
            throw report(error, options)
        }
    }

    /// Decodes `input` into the front of `output`. See ``decode(_:into:options:)``.
    public static func decode(
        _ input: Span<UInt8>, into output: inout MutableSpan<UInt8>, options: Options
    ) throws(DecodeError) -> Int {
        do {
            return try output.withUnsafeMutableBufferPointer { (buffer) throws(DecodeError) in
                try unsafe decodeSpan(input, into: buffer, options: options)
            }
        } catch {
            throw report(error, options)
        }
    }

    // MARK: - Plumbing

    private static func report(_ error: DecodeError, _ options: Options) -> DecodeError {
        options.errorReporting == .uniform ? error.uniform : error
    }

    /// Output bytes to reserve for `count` input bytes: the tight bound, capped by the size limit.
    private static func outputCapacity(forInputCount count: Int, options: Options) -> Int {
        let bound = options.maximumDecodedLength(forEncodedCount: count)
        return options.effectiveMaximumDecodedSize.map { Swift.min(bound, $0) } ?? bound
    }

    private static func decodeCollection(
        _ input: some Collection<UInt8>, into out: UnsafeMutableBufferPointer<UInt8>, options: Options
    ) throws(DecodeError) -> Int {
        // `withContiguousStorageIfAvailable` only `rethrows` untyped errors, so the typed result travels
        // out as a `Result` and is unwrapped here.
        let contiguous = input.withContiguousStorageIfAvailable { (bytes) -> Result<Int, DecodeError> in
            do throws(DecodeError) {
                return .success(try unsafe decodeContiguous(bytes, into: out, options: options))
            } catch {
                return .failure(error)
            }
        }
        if let contiguous { return try contiguous.get() }
        return try unsafe decodeSequential(input, into: out, options: options)
    }

    private static func decodeSpan(
        _ input: Span<UInt8>, into out: UnsafeMutableBufferPointer<UInt8>, options: Options
    ) throws(DecodeError) -> Int {
        try input.withUnsafeBufferPointer { (bytes) throws(DecodeError) in
            try unsafe decodeContiguous(bytes, into: out, options: options)
        }
    }

    private static func decodeContiguous(
        _ input: UnsafeBufferPointer<UInt8>, into out: UnsafeMutableBufferPointer<UInt8>, options: Options
    ) throws(DecodeError) -> Int {
        try options.alphabet.decodeTable.withUnsafeBufferPointer { (lut) throws(DecodeError) in
            var engine = unsafe DecodeEngine(lut: lut, out: out, options: options)
            var index = 0
            let end = input.count
            while index < end {
                if engine.isAtGroupBoundary {
                    unsafe engine.consumeQuanta(input, from: &index)
                    if index == end { break }
                }
                try engine.consume(unsafe input[index], at: index)
                index += 1
            }
            return try engine.finish()
        }
    }

    private static func decodeSequential(
        _ input: some Collection<UInt8>, into out: UnsafeMutableBufferPointer<UInt8>, options: Options
    ) throws(DecodeError) -> Int {
        try options.alphabet.decodeTable.withUnsafeBufferPointer { (lut) throws(DecodeError) in
            var engine = unsafe DecodeEngine(lut: lut, out: out, options: options)
            var offset = 0
            for byte in input {
                try engine.consume(byte, at: offset)
                offset += 1
            }
            return try engine.finish()
        }
    }
}

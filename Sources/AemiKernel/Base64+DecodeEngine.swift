extension Base64 {
    /// The single decode state machine behind every public decode entry point.
    ///
    /// It is fed one byte at a time through ``consume(_:at:)`` (the generic-`Sequence` path and every
    /// slow case) and, when the input is contiguous, takes whole 4-symbol groups through
    /// ``consumeQuanta(_:from:)``, a table-driven loop that falls back to the byte path at the first
    /// byte that is not a plain symbol. Both routes share the one set of rules, so the fast path cannot
    /// accept or reject anything the byte path would not.
    ///
    /// Memory safety: `out` is written only after a check against `limit`, which the constructor caps at
    /// `out.count`, so a write can never leave the caller's buffer.
    @safe struct DecodeEngine {
        private static let lineFeed: UInt8 = 0x0A
        private static let carriageReturn: UInt8 = 0x0D

        private let lut: UnsafeBufferPointer<UInt8>
        private let out: UnsafeMutableBufferPointer<UInt8>
        private let padding: PaddingPolicy
        private let canonical: Bool
        private let whitespace: WhitespacePolicy
        private let lineLimit: Int
        private let limit: Int
        private let limitError: DecodeError

        private var group: UInt32 = 0
        private var count = 0
        private var written = 0
        private var padStart = -1
        private var padCount = 0
        private var lastSymbol = 0
        private var column = 0
        private var pendingCR = -1

        init(
            lut: UnsafeBufferPointer<UInt8>, out: UnsafeMutableBufferPointer<UInt8>, options: Options
        ) {
            unsafe self.lut = lut
            unsafe self.out = out
            padding = options.padding
            canonical = options.trailingBits == .canonical
            whitespace = options.whitespace
            // Columns are only meaningful when line breaks are skipped, so only then is a limit enforced.
            lineLimit = options.whitespace == .reject ? Int.max : (options.effectiveLineLength ?? Int.max)
            if let maximum = options.effectiveMaximumDecodedSize, maximum <= out.count {
                limit = maximum
                limitError = .outputTooLarge(limit: maximum)
            } else {
                limit = out.count
                limitError = .outputBufferTooSmall
            }
        }

        /// Whether no group, padding run, or `CR` is pending, so whole groups can be taken.
        var isAtGroupBoundary: Bool { count == 0 && padStart < 0 && pendingCR < 0 }

        /// Decodes as many whole 4-symbol groups as possible starting at `index`, advancing it. Stops at
        /// the first group that holds a non-symbol byte, would cross the line limit, or would not fit in
        /// the output; the byte path then handles that byte and reports the precise error.
        mutating func consumeQuanta(_ input: UnsafeBufferPointer<UInt8>, from index: inout Int) {
            var position = index
            var cursor = written
            var col = column
            let end = input.count
            while end - position >= 4, limit - cursor >= 3, lineLimit - col >= 4 {
                let a = unsafe lut[Int(unsafe input[position])]
                let b = unsafe lut[Int(unsafe input[position + 1])]
                let c = unsafe lut[Int(unsafe input[position + 2])]
                let d = unsafe lut[Int(unsafe input[position + 3])]
                guard (a | b | c | d) & 0xC0 == 0 else { break }
                unsafe out[cursor] = (a << 2) | (b >> 4)
                unsafe out[cursor + 1] = (b << 4) | (c >> 2)
                unsafe out[cursor + 2] = (c << 6) | d
                position += 4
                cursor += 3
                col += 4
            }
            index = position
            written = cursor
            column = col
        }

        /// Consumes the byte `byte` found at input offset `offset`.
        mutating func consume(_ byte: UInt8, at offset: Int) throws(DecodeError) {
            if pendingCR >= 0 {
                guard byte == Self.lineFeed else {
                    throw .invalidByte(Self.carriageReturn, offset: pendingCR)
                }
                pendingCR = -1
                column = 0
                return
            }
            let sextet = unsafe lut[Int(byte)]
            if sextet < 64 {
                try consumeSymbol(sextet, at: offset)
            } else if byte == Base64.padByte {
                try consumePadding(at: offset)
            } else {
                try consumeSeparator(byte, at: offset)
            }
        }

        private mutating func consumeSymbol(_ sextet: UInt8, at offset: Int) throws(DecodeError) {
            guard padStart < 0 else { throw .invalidPadding(offset: padStart) }
            try advanceColumn(at: offset)
            group = (group << 6) | UInt32(sextet)
            lastSymbol = offset
            count += 1
            if count == 4 {
                try emit(3)
                unsafe out[written - 3] = UInt8(truncatingIfNeeded: group >> 16)
                unsafe out[written - 2] = UInt8(truncatingIfNeeded: group >> 8)
                unsafe out[written - 1] = UInt8(truncatingIfNeeded: group)
                group = 0
                count = 0
            }
        }

        private mutating func consumePadding(at offset: Int) throws(DecodeError) {
            guard padding != .forbidden else { throw .invalidPadding(offset: offset) }
            try advanceColumn(at: offset)
            if padStart < 0 { padStart = offset }
            padCount += 1
        }

        private mutating func consumeSeparator(_ byte: UInt8, at offset: Int) throws(DecodeError) {
            switch whitespace {
                case .reject:
                    throw .invalidByte(byte, offset: offset)
                case .skipLineBreaks:
                    if byte == Self.lineFeed {
                        column = 0
                    } else if byte == Self.carriageReturn {
                        pendingCR = offset
                    } else {
                        throw .invalidByte(byte, offset: offset)
                    }
                case .skipAll:
                    if byte == Self.lineFeed || byte == Self.carriageReturn {
                        column = 0
                    } else if !Self.isSpace(byte) {
                        throw .invalidByte(byte, offset: offset)
                    }
            }
        }

        private static func isSpace(_ byte: UInt8) -> Bool {
            byte == 0x20 || byte == 0x09 || byte == 0x0B || byte == 0x0C
        }

        private mutating func advanceColumn(at offset: Int) throws(DecodeError) {
            column += 1
            if column > lineLimit { throw .lineTooLong(offset: offset) }
        }

        /// Reserves `extra` output bytes, throwing the limit error if they do not fit.
        private mutating func emit(_ extra: Int) throws(DecodeError) {
            guard limit - written >= extra else { throw limitError }
            written += extra
        }

        /// Validates the end of input and writes the final partial group. Returns the decoded size.
        mutating func finish() throws(DecodeError) -> Int {
            if pendingCR >= 0 { throw .invalidByte(Self.carriageReturn, offset: pendingCR) }
            if count == 1 { throw .invalidLength }
            try checkPaddingAtEnd()
            if count != 0 {
                if canonical {
                    let unused: UInt32 = count == 2 ? 0xF : 0x3
                    guard group & unused == 0 else { throw .nonCanonicalBits(offset: lastSymbol) }
                }
                try emit(count - 1)
                if count == 2 {
                    unsafe out[written - 1] = UInt8(truncatingIfNeeded: group >> 4)
                } else {
                    unsafe out[written - 2] = UInt8(truncatingIfNeeded: group >> 10)
                    unsafe out[written - 1] = UInt8(truncatingIfNeeded: group >> 2)
                }
            }
            return written
        }

        private func checkPaddingAtEnd() throws(DecodeError) {
            switch padding {
                case .tolerated, .forbidden:
                    return
                case .required, .optional:
                    if padCount > 0 {
                        let expected = count == 0 ? 0 : 4 - count
                        guard padCount == expected else { throw .invalidPadding(offset: padStart) }
                    } else if padding == .required, count != 0 {
                        throw .invalidLength
                    }
            }
        }
    }
}

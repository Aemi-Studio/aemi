import AemiKernel
import Testing

struct Base64DecodingTests {
    private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }
    private func text(_ b: [UInt8]) -> String { String(decoding: b, as: UTF8.self) }

    /// Decodes with `options` and returns the thrown error, or `nil` if the decode succeeded.
    private func failure(_ input: String, _ options: Base64.Options) -> Base64.DecodeError? {
        do {
            _ = try Base64.decode(input, options: options)
            return nil
        } catch {
            return error
        }
    }

    // MARK: - RFC 4648 §10 vectors, every preset

    private static let plain = ["", "f", "fo", "foo", "foob", "fooba", "foobar"]
    private static let padded = ["", "Zg==", "Zm8=", "Zm9v", "Zm9vYg==", "Zm9vYmE=", "Zm9vYmFy"]
    private static let unpadded = ["", "Zg", "Zm8", "Zm9v", "Zm9vYg", "Zm9vYmE", "Zm9vYmFy"]

    @Test func paddedPresetsDecodeTheRFCVectors() throws {
        for options in [Base64.Options.strict, .urlSafe, .mime, .pem, .lenient] {
            for (plain, encoded) in zip(Self.plain, Self.padded) {
                #expect(try text(Base64.decode(encoded, options: options)) == plain)
            }
        }
    }

    @Test func unpaddedPresetDecodesTheRFCVectors() throws {
        for (plain, encoded) in zip(Self.plain, Self.unpadded) {
            #expect(try text(Base64.decode(encoded, options: .urlSafeNoPadding)) == plain)
        }
    }

    @Test func optionalAndLenientAcceptBothPaddedAndUnpadded() throws {
        var optional = Base64.Options.strict
        optional.padding = .optional
        for options in [optional, .lenient] {
            for (plain, a, b) in zip3(Self.plain, Self.padded, Self.unpadded) {
                #expect(try text(Base64.decode(a, options: options)) == plain)
                #expect(try text(Base64.decode(b, options: options)) == plain)
            }
        }
    }

    private func zip3(_ a: [String], _ b: [String], _ c: [String]) -> [(String, String, String)] {
        (0 ..< a.count).map { (a[$0], b[$0], c[$0]) }
    }

    @Test func urlSafeAlphabetDecodesDashAndUnderscore() throws {
        #expect(try Base64.decode("____", options: .urlSafe) == [0xFF, 0xFF, 0xFF])
        #expect(try Base64.decode("-_-_", options: .urlSafe) == [0xFB, 0xFF, 0xBF])
        #expect(failure("////", .urlSafe) == .invalidByte(UInt8(ascii: "/"), offset: 0))
        #expect(failure("-_-_", .strict) == .invalidByte(UInt8(ascii: "-"), offset: 0))
    }

    // MARK: - .strict: every malformed class

    @Test func strictRejectsMalformedInputWithTheRightError() {
        let cases: [(String, Base64.DecodeError)] = [
            ("Zg===", .invalidPadding(offset: 2)),  // three '='
            ("Zg=", .invalidPadding(offset: 2)),  // one '=' where two are needed
            ("Zm8==", .invalidPadding(offset: 3)),  // two '=' where one is needed
            ("====", .invalidPadding(offset: 0)),  // padding only
            ("Zm9v====", .invalidPadding(offset: 4)),  // padding after a complete group
            ("Zm9v=", .invalidPadding(offset: 4)),
            ("Z===", .invalidLength),  // one data symbol
            ("Zm9vY", .invalidLength),  // lone trailing sextet
            ("Zg", .invalidLength),  // padding missing
            ("Zm8", .invalidLength),
            ("Zh==", .nonCanonicalBits(offset: 1)),  // 'h' leaves a 1 in the unused low bits
            ("Zm9=", .nonCanonicalBits(offset: 2)),
            ("Zm9v=Zm9v", .invalidPadding(offset: 4)),  // '=' in the middle
            ("Zg==Zg==", .invalidPadding(offset: 2)),
            ("Zm=v", .invalidPadding(offset: 2)),
            ("=Zg=", .invalidPadding(offset: 0)),
            ("Zm 9v", .invalidByte(0x20, offset: 2)),  // embedded whitespace
            ("Zm9v\n", .invalidByte(0x0A, offset: 4)),
            ("Zm9v\r\n", .invalidByte(0x0D, offset: 4)),
            ("\tZm9v", .invalidByte(0x09, offset: 0)),
            ("Zg=\n=", .invalidByte(0x0A, offset: 3)),
            ("Zg$=", .invalidByte(UInt8(ascii: "$"), offset: 2)),
            ("Zm9-", .invalidByte(UInt8(ascii: "-"), offset: 3)),
            ("Zg==\0", .invalidByte(0, offset: 4))
        ]
        for (input, expected) in cases {
            #expect(failure(input, .strict) == expected, "input: \(input.debugDescription)")
        }
    }

    @Test func strictAcceptsTheEmptyInput() throws {
        #expect(try Base64.decode("", options: .strict).isEmpty)
        #expect(try Base64.decode([UInt8](), options: .strict).isEmpty)
    }

    @Test func strictRejectsAnyNonAlphabetByteAtEveryPosition() {
        let valid = bytes("Zm9vYmFyZm9vYmFyZm9vYmE=")  // 24 chars: groups, then a padded tail
        for position in 0 ..< valid.count {
            for stray in [UInt8(ascii: "*"), 0x00, 0x80, 0xFF, UInt8(ascii: " "), 0x0A] {
                var broken = valid
                broken[position] = stray
                var thrown: Base64.DecodeError?
                do { _ = try Base64.decode(broken, options: .strict) } catch { thrown = error }
                #expect(thrown == .invalidByte(stray, offset: position), "stray \(stray) at \(position)")
            }
        }
    }

    @Test func strictRejectsEveryNonCanonicalFinalSymbol() throws {
        // For "fo" the last symbol is the sextet 'm8=' group: only the symbols whose low 2 bits are zero decode.
        let symbols = Base64.AlphabetTable.standard.symbols
        var accepted = 0
        for (value, symbol) in symbols.enumerated() {
            let input: [UInt8] = bytes("Zm") + [symbol, UInt8(ascii: "=")]
            let result = try? Base64.decode(input, options: .strict)
            if value & 0x3 == 0 {
                #expect(result != nil)
                accepted += 1
            } else {
                #expect(result == nil)
            }
        }
        #expect(accepted == 16)
    }

    @Test func lenientAcceptsNonCanonicalBitsButCanonicalDoesNot() throws {
        #expect(try Base64.decode("Zh==", options: .lenient) == bytes("f"))
        #expect(try Base64.decode("Zg==", options: .lenient) == bytes("f"))
        var canonical = Base64.Options.lenient
        canonical.trailingBits = .canonical
        #expect(failure("Zh==", canonical) == .nonCanonicalBits(offset: 1))
    }

    // MARK: - Padding policies

    @Test func forbiddenPaddingRejectsEqualsSigns() throws {
        #expect(failure("Zg==", .urlSafeNoPadding) == .invalidPadding(offset: 2))
        #expect(failure("Zm9v=", .urlSafeNoPadding) == .invalidPadding(offset: 4))
        #expect(failure("Zm9vY", .urlSafeNoPadding) == .invalidLength)
        #expect(try Base64.decode("Zm9vYg", options: .urlSafeNoPadding) == bytes("foob"))
    }

    @Test func optionalPaddingRequiresExactlyTheRightAmountWhenPresent() {
        var options = Base64.Options.strict
        options.padding = .optional
        #expect(failure("Zg=", options) == .invalidPadding(offset: 2))
        #expect(failure("Zg===", options) == .invalidPadding(offset: 2))
        #expect(failure("====", options) == .invalidPadding(offset: 0))
        #expect(failure("Zm9v=", options) == .invalidPadding(offset: 4))
        #expect(failure("Zg", options) == nil)
    }

    // MARK: - .lenient keeps the historical behavior

    @Test func lenientMatchesTheLegacyNilReturningDecode() {
        let inputs = ["Zg===", "Zg=", "====", "Zg", "Zm9vY", "Zg==X", "Zg$=", "Z=", "=", "Zm9v=Zm9v", "Zh=="]
        for input in inputs {
            let legacy = Base64.decode(bytes(input))
            let modern = try? Base64.decode(input, options: .lenient)
            #expect(legacy == modern, "input: \(input)")
        }
        // The documented quirks stay: any '=' run is skipped.
        #expect(Base64.decode(bytes("Zg===")) == bytes("f"))
        #expect(Base64.decode(bytes("Zg=")) == bytes("f"))
        #expect(Base64.decode(bytes("====")) == [])
        #expect(Base64.decode(bytes("Zm9v=Zm9v")) == nil)
    }

    // MARK: - Whitespace and lines

    @Test func skipLineBreaksAcceptsLFAndCRLF() throws {
        var options = Base64.Options.strict
        options.whitespace = .skipLineBreaks
        #expect(try Base64.decode("Zm9v\nYmFy\n", options: options) == bytes("foobar"))
        #expect(try Base64.decode("Zm9v\r\nYmFy\r\n", options: options) == bytes("foobar"))
        #expect(try Base64.decode("Zm\n9vYg\n==", options: options) == bytes("foob"))
        #expect(try Base64.decode("\n\nZm9v\n\n", options: options) == bytes("foo"))
    }

    @Test func skipLineBreaksRejectsBareCRAndOtherSpaces() {
        var options = Base64.Options.strict
        options.whitespace = .skipLineBreaks
        #expect(failure("Zm9v\rYmFy", options) == .invalidByte(0x0D, offset: 4))
        #expect(failure("Zm9v\r", options) == .invalidByte(0x0D, offset: 4))
        #expect(failure("Zm9v\r\rYmFy", options) == .invalidByte(0x0D, offset: 4))
        #expect(failure("Zm9v YmFy", options) == .invalidByte(0x20, offset: 4))
        #expect(failure("Zm9v\tYmFy", options) == .invalidByte(0x09, offset: 4))
    }

    @Test func skipAllAcceptsSpacesTabsAndAnyLineBreak() throws {
        var options = Base64.Options.strict
        options.whitespace = .skipAll
        #expect(try Base64.decode(" Zm9v\tYm\u{0B}Fy\u{0C}\r\n\r \n", options: options) == bytes("foobar"))
        #expect(failure("Zm9v*YmFy", options) == .invalidByte(UInt8(ascii: "*"), offset: 4))
        // Skipped bytes do not excuse a bad structure.
        #expect(failure("Zm9vY\n", options) == .invalidLength)
        #expect(failure("Zg=\n=\n=", options) == .invalidPadding(offset: 2))
    }

    @Test func pemAndMimeEnforceTheirLineLengths() throws {
        let line64 = String(repeating: "A", count: 64)
        let line65 = String(repeating: "A", count: 65)
        #expect(try Base64.decode(line64 + "\n" + line64 + "\n", options: .pem).count == 96)
        #expect(failure(line65 + "\n", .pem) == .lineTooLong(offset: 64))
        #expect(failure(line64 + "\n" + line65, .pem) == .lineTooLong(offset: 64 + 1 + 64))
        let line76 = String(repeating: "A", count: 76)
        #expect(try Base64.decode(line76 + "\r\n" + line76, options: .mime).count == 114)
        #expect(failure(line76 + "A", .mime) == .lineTooLong(offset: 76))
        // The padding on the last line counts toward its length.
        #expect(failure(String(repeating: "A", count: 61) + "A==", .pem) == nil)
        #expect(failure(String(repeating: "A", count: 62) + "A==", .pem) == .lineTooLong(offset: 64))
    }

    @Test func lineLimitIsIgnoredWhenWhitespaceIsRejected() throws {
        var options = Base64.Options.strict
        options.lineLength = 4
        #expect(try Base64.decode("Zm9vYmFy", options: options) == bytes("foobar"))
    }

    @Test func nonPositiveLineLengthFailsClosed() {
        var options = Base64.Options.pem
        options.lineLength = 0
        #expect(failure("AAAA", options) == .lineTooLong(offset: 1))
    }

    @Test func pemDecodesAWrappedBodyProducedElsewhere() throws {
        let body = "TWFueSBoYW5kcyBtYWtlIGxpZ2h0IHdvcmsu\nTWFueSBoYW5kcyBtYWtlIGxpZ2h0IHdvcmsu\n"
        let decoded = try Base64.decode(body, options: .pem)
        #expect(text(decoded) == "Many hands make light work.Many hands make light work.")
    }

    // MARK: - Maximum size, error reporting

    @Test func maximumDecodedSizeIsEnforced() throws {
        var options = Base64.Options.strict
        options.maximumDecodedSize = 6
        #expect(try Base64.decode("Zm9vYmFy", options: options) == bytes("foobar"))
        #expect(failure("Zm9vYmFyZg==", options) == .outputTooLarge(limit: 6))
        options.maximumDecodedSize = 0
        #expect(try Base64.decode("", options: options).isEmpty)
        #expect(failure("Zg==", options) == .outputTooLarge(limit: 0))
        options.maximumDecodedSize = -5
        #expect(failure("Zg==", options) == .outputTooLarge(limit: 0))
    }

    @Test func uniformReportingHidesTheCauseButNotTheSizeLimit() {
        var options = Base64.Options.strict
        options.errorReporting = .uniform
        for input in ["Zg=", "Zh==", "Zm 9v", "Zm9vY", "Zg$="] {
            #expect(failure(input, options) == .malformed, "input: \(input)")
        }
        var pem = Base64.Options.pem
        pem.errorReporting = .uniform
        #expect(failure(String(repeating: "A", count: 65), pem) == .malformed)
        options.maximumDecodedSize = 1
        #expect(failure("Zm9v", options) == .outputTooLarge(limit: 1))
    }

    // MARK: - Input forms

    @Test func everyInputFormGivesTheSameResultAndError() throws {
        let inputs = ["Zm9vYmFy", "Zm9vYg==", "", "Zg=", "Zh==", "Zm9v\n", "Zm9v=Zm9v", "Zm9vY"]
        for input in inputs {
            let array = bytes(input)
            let expected = try? Base64.decode(array, options: .strict)
            var expectedError: Base64.DecodeError?
            do { _ = try Base64.decode(array, options: .strict) } catch { expectedError = error }

            let fromString = try? Base64.decode(input, options: .strict)
            let fromSubstring = try? Base64.decode(Substring(input), options: .strict)
            let fromSlice = try? Base64.decode(array[...], options: .strict)
            let fromGeneric = try? Base64.decode(NonContiguousBytes(storage: array), options: .strict)
            let fromSpan = try? SpanAccess.read(array) { try Base64.decode($0, options: .strict) }
            #expect(fromString == expected)
            #expect(fromSubstring == expected)
            #expect(fromSlice == expected)
            #expect(fromGeneric == expected)
            #expect(fromSpan == expected)

            var errorFromGeneric: Base64.DecodeError?
            do { _ = try Base64.decode(NonContiguousBytes(storage: array), options: .strict) } catch {
                errorFromGeneric = error
            }
            #expect(errorFromGeneric == expectedError)
        }
    }

    @Test func slicesDecodeFromTheirOwnStart() throws {
        let framed = bytes("xx") + bytes("Zm9v") + bytes("yy")
        #expect(try Base64.decode(framed[2 ..< 6], options: .strict) == bytes("foo"))
        // Offsets are relative to the start of the slice, not of the parent array.
        let broken = bytes("xx") + bytes("Zm9*") + bytes("yy")
        var thrown: Base64.DecodeError?
        do { _ = try Base64.decode(broken[2 ..< 6], options: .strict) } catch { thrown = error }
        #expect(thrown == .invalidByte(UInt8(ascii: "*"), offset: 3))
    }

    // MARK: - decode(into:) bounds

    @discardableResult
    private func decodeInto(
        _ input: String, capacity: Int, _ options: Base64.Options
    ) throws(Base64.DecodeError) -> (written: Int, window: [UInt8]) {
        try Base64.decodeCanary(bytes(input), capacity: capacity, options: options)
    }

    @Test func decodeIntoWritesExactlyTheDecodedBytes() throws {
        let result = try decodeInto("Zm9vYmFy", capacity: 6, .strict)
        #expect(result.written == 6)
        #expect(result.window == bytes("foobar"))
        let roomy = try decodeInto("Zm9vYg==", capacity: 40, .strict)
        #expect(roomy.written == 4)
        #expect(Array(roomy.window[..<4]) == bytes("foob"))
    }

    @Test func decodeIntoThrowsWhenTheBufferIsTooSmallAtEverySize() throws {
        let input = "Zm9vYmFyZm9vYmE="  // 11 bytes
        for capacity in 0 ..< 11 {
            #expect(throws: Base64.DecodeError.outputBufferTooSmall) {
                try decodeInto(input, capacity: capacity, .strict)
            }
        }
        #expect(try decodeInto(input, capacity: 11, .strict).written == 11)
    }

    @Test func decodeIntoTailOverflowThrows() {
        // The partial final group is the part that does not fit: 3 bytes in a 2-byte buffer.
        #expect(throws: Base64.DecodeError.outputBufferTooSmall) {
            try decodeInto("Zm9v", capacity: 2, .strict)
        }
        #expect(throws: Base64.DecodeError.outputBufferTooSmall) {
            try decodeInto("Zm8=", capacity: 1, .strict)
        }
        #expect(throws: Base64.DecodeError.outputBufferTooSmall) {
            try decodeInto("Zg==", capacity: 0, .strict)
        }
    }

    @Test func decodeIntoHonorsTheSmallerOfBufferAndMaximumSize() {
        var options = Base64.Options.strict
        options.maximumDecodedSize = 3
        #expect(throws: Base64.DecodeError.outputTooLarge(limit: 3)) {
            try decodeInto("Zm9vYmFy", capacity: 100, options)
        }
        #expect(throws: Base64.DecodeError.outputBufferTooSmall) {
            try decodeInto("Zm9vYmFy", capacity: 2, options)
        }
    }

    @Test func decodeIntoAcceptsSpanInputAndGenericCollections() throws {
        let input = bytes("Zm9vYmFy")
        let fromGeneric = try Base64.decodeCanary(NonContiguousBytes(storage: input), capacity: 6, options: .strict)
        #expect(fromGeneric.window == bytes("foobar"))
        var storage = [UInt8](repeating: 0, count: 6)
        let written = try SpanAccess.read(input) { (span) throws(Base64.DecodeError) in
            try SpanAccess.write(&storage) { (out) throws(Base64.DecodeError) in
                try Base64.decode(span, into: &out, options: .strict)
            }
        }
        #expect(written == 6)
        #expect(storage == bytes("foobar"))
    }

    @Test func decodeIntoBufferPointerHonorsItsBounds() throws {
        var storage = [UInt8](repeating: canaryByte, count: 10)
        let written = try storage.withUnsafeMutableBufferPointer { out in
            try Base64.decode(
                bytes("Zm9vYmFy"), into: UnsafeMutableBufferPointer(rebasing: out[..<6]), options: .strict)
        }
        #expect(written == 6)
        #expect(Array(storage[..<6]) == bytes("foobar"))
        #expect(storage[6...].allSatisfy { $0 == canaryByte })
        let tooSmall = storage.withUnsafeMutableBufferPointer { (out) -> Base64.DecodeError? in
            do throws(Base64.DecodeError) {
                _ = try Base64.decode(
                    bytes("Zm9vYmFy"), into: UnsafeMutableBufferPointer(rebasing: out[..<5]), options: .strict)
                return nil
            } catch {
                return error
            }
        }
        #expect(tooSmall == .outputBufferTooSmall)
        #expect(storage[6...].allSatisfy { $0 == canaryByte })
        // An empty buffer has no base address; it must still decode the empty text and refuse any other.
        var none: [UInt8] = []
        let empty = try none.withUnsafeMutableBufferPointer { out in
            try Base64.decode(bytes(""), into: out, options: .strict)
        }
        #expect(empty == 0)
    }
}

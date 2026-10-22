import AemiKernel
import Testing

struct Base64EncodingTests {
    private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    private static let plain = ["", "f", "fo", "foo", "foob", "fooba", "foobar"]
    private static let padded = ["", "Zg==", "Zm8=", "Zm9v", "Zm9vYg==", "Zm9vYmE=", "Zm9vYmFy"]
    private static let unpadded = ["", "Zg", "Zm8", "Zm9v", "Zm9vYg", "Zm9vYmE", "Zm9vYmFy"]

    @Test func paddedPresetsEncodeTheRFCVectors() {
        for options in [Base64.Options.strict, .urlSafe, .mime, .pem, .lenient] {
            for (plain, encoded) in zip(Self.plain, Self.padded) {
                #expect(Base64.encodedString(Array(plain.utf8), options: options) == encoded)
            }
        }
    }

    @Test func unpaddedPresetEncodesTheRFCVectors() {
        for (plain, encoded) in zip(Self.plain, Self.unpadded) {
            #expect(Base64.encodedString(Array(plain.utf8), options: .urlSafeNoPadding) == encoded)
        }
    }

    @Test func urlSafeAlphabetUsesDashAndUnderscore() {
        let bytes: [UInt8] = [0xFB, 0xFF, 0xBF, 0xFF]
        #expect(Base64.encodedString(bytes, options: .strict) == "+/+//w==")
        #expect(Base64.encodedString(bytes, options: .urlSafe) == "-_-__w==")
        #expect(Base64.encodedString(bytes, options: .urlSafeNoPadding) == "-_-__w")
    }

    @Test func customAlphabetEncodes() throws {
        let rotated = Array(Base64.AlphabetTable.standard.symbols.dropFirst()) + [UInt8(ascii: "A")]
        var options = Base64.Options.strict
        options.alphabet = try Base64.AlphabetTable(symbols: rotated)
        // Every sextet maps one symbol along: "Zm9v" -> "an+w".
        #expect(Base64.encodedString(bytes("foo"), options: options) == "an+w")
    }

    @Test func wrapsAtTheConfiguredWidthWithoutATrailingSeparator() {
        let zeros57 = [UInt8](repeating: 0, count: 57)
        let line76 = String(repeating: "A", count: 76)
        #expect(Base64.encodedString(zeros57, options: .mime) == line76)
        #expect(Base64.encodedString(zeros57 + [0], options: .mime) == line76 + "\r\nAA==")
        let zeros48 = [UInt8](repeating: 0, count: 48)
        let line64 = String(repeating: "A", count: 64)
        #expect(Base64.encodedString(zeros48, options: .pem) == line64)
        #expect(Base64.encodedString(zeros48 + zeros48, options: .pem) == line64 + "\n" + line64)
        #expect(Base64.encodedString([], options: .pem).isEmpty)
    }

    @Test func wrapsAtArbitraryWidthsAndEndings() {
        var options = Base64.Options.strict
        options.lineLength = 5
        options.lineEnding = .crlf
        #expect(Base64.encodedString(bytes("foobar"), options: options) == "Zm9vY\r\nmFy")
        options.lineLength = 1
        options.lineEnding = .lf
        #expect(Base64.encodedString(bytes("foo"), options: options) == "Z\nm\n9\nv")
        options.lineLength = 100
        #expect(Base64.encodedString(bytes("foobar"), options: options) == "Zm9vYmFy")
        options.lineLength = 0  // clamps to 1
        #expect(Base64.encodedString(bytes("fo"), options: options) == "Z\nm\n8\n=")
    }

    @Test func wrappingMatchesANaiveWrapForEverySizeWidthAndEnding() {
        let source = (0 ..< 200).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) }
        for count in 0 ... 200 {
            for width in [1, 3, 4, 5, 16, 64, 76, 400] {
                for ending in [Base64.LineEnding.lf, .crlf] {
                    var options = Base64.Options.strict
                    options.lineLength = width
                    options.lineEnding = ending
                    let input = Array(source.prefix(count))
                    #expect(Base64.encode(input, options: options) == ReferenceBase64.encode(input, options))
                }
            }
        }
    }

    @Test func encodedLengthMatchesTheActualOutput() {
        for count in 0 ... 300 {
            let input = [UInt8](repeating: 0x5A, count: count)
            for options in Base64Generators.presets {
                #expect(options.encodedLength(forByteCount: count) == Base64.encode(input, options: options).count)
            }
        }
    }

    @Test func nonContiguousAndSpanInputsEncodeLikeAnArray() {
        let input = (0 ..< 77).map { UInt8($0) }
        let expected = Base64.encode(input, options: .mime)
        #expect(Base64.encode(NonContiguousBytes(storage: input), options: .mime) == expected)
        #expect(SpanAccess.read(input) { Base64.encode($0, options: .mime) } == expected)
        #expect(Base64.encode(input[...], options: .mime) == expected)
    }

    @Test func legacyOverloadsMatchTheOptionsForm() {
        let input = (0 ..< 50).map { UInt8($0 &* 5) }
        #expect(Base64.encode(input) == Base64.encode(input, options: .strict))
        #expect(
            Base64.encode(input, alphabet: .urlSafe, padding: false) == Base64.encode(input, options: .urlSafeNoPadding)
        )
        #expect(Base64.encode(input, alphabet: .urlSafe) == Base64.encode(input, options: .urlSafe))
        var unpadded = Base64.Options.strict
        unpadded.padding = .forbidden
        #expect(Base64.encode(input, padding: false) == Base64.encode(input, options: unpadded))
    }

    // MARK: - encode(into:)

    @discardableResult
    private func encodeInto(
        _ input: [UInt8], capacity: Int, _ options: Base64.Options
    ) throws(Base64.EncodeError) -> (written: Int, window: [UInt8]) {
        try Base64.encodeCanary(input, capacity: capacity, options: options)
    }

    @Test func encodeIntoWritesExactlyTheEncodedBytes() throws {
        let input = (0 ..< 100).map { UInt8($0) }
        for options in Base64Generators.presets {
            let expected = Base64.encode(input, options: options)
            let result = try encodeInto(input, capacity: expected.count + 7, options)
            #expect(result.written == expected.count)
            #expect(Array(result.window[..<expected.count]) == expected)
            // The spare room beyond the output is untouched.
            #expect(result.window[expected.count...].allSatisfy { $0 == canaryByte })
        }
    }

    @Test func encodeIntoThrowsWhenTheBufferIsTooSmallAtEverySize() throws {
        let input = (0 ..< 40).map { UInt8($0) }
        for options in [Base64.Options.strict, .pem] {
            let needed = try #require(options.encodedLength(forByteCount: input.count))
            for capacity in 0 ..< needed {
                #expect(throws: Base64.EncodeError.outputBufferTooSmall(required: needed)) {
                    try encodeInto(input, capacity: capacity, options)
                }
            }
            #expect(try encodeInto(input, capacity: needed, options).written == needed)
        }
    }

    @Test func encodeIntoAcceptsSpanAndGenericInput() throws {
        let input = bytes("foobar")
        #expect(
            try Base64.encodeCanary(NonContiguousBytes(storage: input), capacity: 8, options: .strict).window
                == bytes("Zm9vYmFy"))
        var storage = [UInt8](repeating: 0, count: 8)
        let written = try SpanAccess.read(input) { (span) throws(Base64.EncodeError) in
            try SpanAccess.write(&storage) { (out) throws(Base64.EncodeError) in
                try Base64.encode(span, into: &out, options: .strict)
            }
        }
        #expect(written == 8)
        #expect(storage == bytes("Zm9vYmFy"))
    }

    @Test func encodeIntoBufferPointerHonorsItsBounds() throws {
        var storage = [UInt8](repeating: canaryByte, count: 12)
        let written = try storage.withUnsafeMutableBufferPointer { out in
            try Base64.encode(bytes("foobar"), into: UnsafeMutableBufferPointer(rebasing: out[..<8]), options: .strict)
        }
        #expect(written == 8)
        #expect(Array(storage[..<8]) == bytes("Zm9vYmFy"))
        #expect(storage[8...].allSatisfy { $0 == canaryByte })
        let failure = storage.withUnsafeMutableBufferPointer { (out) -> Base64.EncodeError? in
            do throws(Base64.EncodeError) {
                _ = try Base64.encode(
                    bytes("foobar"), into: UnsafeMutableBufferPointer(rebasing: out[..<7]), options: .strict)
                return nil
            } catch {
                return error
            }
        }
        #expect(failure == .outputBufferTooSmall(required: 8))
    }

    // MARK: - Large input

    @Test func largeInputsRoundTripOnBothPaths() throws {
        let original = (0 ..< 300_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ ($0 >> 8)) }
        for options in [Base64.Options.strict, .urlSafeNoPadding, .mime, .pem] {
            let encoded = Base64.encode(original, options: options)
            #expect(try Base64.decode(encoded, options: options) == original)
            #expect(try Base64.decode(NonContiguousBytes(storage: encoded), options: options) == original)
        }
    }
}

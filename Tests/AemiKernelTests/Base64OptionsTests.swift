import AemiKernel
import Testing

struct Base64OptionsTests {
    private let standardSymbols = Base64.AlphabetTable.standard.symbols

    @Test func builtInAlphabetsMatchTheRFC() {
        #expect(String(decoding: Base64.AlphabetTable.standard.symbols, as: UTF8.self).suffix(2) == "+/")
        #expect(String(decoding: Base64.AlphabetTable.urlSafe.symbols, as: UTF8.self).suffix(2) == "-_")
        #expect(Base64.AlphabetTable(.standard) == .standard)
        #expect(Base64.AlphabetTable(.urlSafe) == .urlSafe)
        #expect(Base64.AlphabetTable.standard.symbols.count == 64)
    }

    @Test func customAlphabetAcceptsAnyPermutationOfDistinctPrintableBytes() throws {
        let reversed = Array(standardSymbols.reversed())
        let table = try Base64.AlphabetTable(symbols: reversed)
        #expect(table.symbols == reversed)
        #expect(table != .standard)
        #expect(try Base64.AlphabetTable(symbols: standardSymbols) == .standard)
    }

    @Test func customAlphabetRejectsWrongCount() {
        #expect(throws: Base64.AlphabetError.wrongSymbolCount(63)) {
            try Base64.AlphabetTable(symbols: standardSymbols.dropLast())
        }
        #expect(throws: Base64.AlphabetError.wrongSymbolCount(65)) {
            try Base64.AlphabetTable(symbols: standardSymbols + [UInt8(ascii: "~")])
        }
        #expect(throws: Base64.AlphabetError.wrongSymbolCount(0)) {
            try Base64.AlphabetTable(symbols: [UInt8]())
        }
    }

    @Test func customAlphabetRejectsDuplicates() {
        var symbols = standardSymbols
        symbols[63] = symbols[0]
        #expect(throws: Base64.AlphabetError.duplicateSymbol(UInt8(ascii: "A"))) {
            try Base64.AlphabetTable(symbols: symbols)
        }
    }

    @Test(arguments: [UInt8(ascii: "="), 0x20, 0x0A, 0x0D, 0x09, 0x00, 0x7F, 0x80, 0xFF])
    func customAlphabetRejectsPaddingWhitespaceControlAndNonASCII(bad: UInt8) {
        var symbols = standardSymbols
        symbols[10] = bad
        #expect(throws: Base64.AlphabetError.unsupportedSymbol(bad)) {
            try Base64.AlphabetTable(symbols: symbols)
        }
    }

    @Test func presetsHaveTheDocumentedShape() {
        #expect(Base64.Options.strict.padding == .required)
        #expect(Base64.Options.strict.trailingBits == .canonical)
        #expect(Base64.Options.strict.whitespace == .reject)
        #expect(Base64.Options.urlSafe.alphabet == .urlSafe)
        #expect(Base64.Options.urlSafe.padding == .required)
        #expect(Base64.Options.urlSafeNoPadding.padding == .forbidden)
    }

    @Test func wrappedPresetsHaveTheDocumentedShape() {
        #expect(Base64.Options.mime.lineLength == 76)
        #expect(Base64.Options.mime.lineEnding == .crlf)
        #expect(Base64.Options.pem.lineLength == 64)
        #expect(Base64.Options.pem.lineEnding == .lf)
        #expect(Base64.Options.lenient == Base64.Options())
        #expect(Base64.Options.lenient.padding == .tolerated)
        #expect(Base64.Options.lenient.trailingBits == .lenient)
    }

    @Test func encodedLengthIsExact() {
        let strict = Base64.Options.strict
        let unpadded = Base64.Options.urlSafeNoPadding
        let expectedPadded = [0, 4, 4, 4, 8, 8, 8, 12]
        let expectedUnpadded = [0, 2, 3, 4, 6, 7, 8, 10]
        for count in 0 ... 7 {
            #expect(strict.encodedLength(forByteCount: count) == expectedPadded[count])
            #expect(unpadded.encodedLength(forByteCount: count) == expectedUnpadded[count])
        }
        // 57 bytes -> 76 characters (one full MIME line); 58 bytes -> 80 characters -> two lines.
        #expect(Base64.Options.mime.encodedLength(forByteCount: 57) == 76)
        #expect(Base64.Options.mime.encodedLength(forByteCount: 58) == 76 + 2 + 4)
        #expect(Base64.Options.pem.encodedLength(forByteCount: 48) == 64)
        #expect(Base64.Options.pem.encodedLength(forByteCount: 49) == 64 + 1 + 4)
    }

    @Test func encodedLengthReportsOverflowAndRejectsNegative() {
        #expect(Base64.Options.strict.encodedLength(forByteCount: Int.max) == nil)
        #expect(Base64.Options.strict.encodedLength(forByteCount: -1) == nil)
    }

    @Test func maximumDecodedLengthBoundsEveryValidDecode() {
        for count in 0 ... 64 {
            let encodedCount = (count + 2) / 3 * 4  // padded encoding of `count` bytes
            let bound = Base64.Options.strict.maximumDecodedLength(forEncodedCount: encodedCount)
            #expect(bound >= count)
            #expect(bound - count <= 2)
        }
        #expect(Base64.Options.strict.maximumDecodedLength(forEncodedCount: 0) == 0)
        #expect(Base64.Options.strict.maximumDecodedLength(forEncodedCount: Int.max) > 0)
    }
}

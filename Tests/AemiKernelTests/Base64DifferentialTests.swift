import AemiKernel
import AemiTestKit
import Testing

/// The codec against an independent naive reference: random options, random and mutated inputs, every
/// option combination round-tripped, and the canonical-form guarantee of `.strict`.
@Suite(.tags(.parity))
struct Base64DifferentialTests {
    private func attempt(_ input: [UInt8], _ options: Base64.Options) -> [UInt8]? {
        try? Base64.decode(input, options: options)
    }

    /// Runs every decode entry point on `input` and checks them against the reference.
    private func expectAgreement(_ input: [UInt8], _ options: Base64.Options, label: String) {
        let expected = ReferenceBase64.decode(input, options)
        let contiguous = attempt(input, options)
        let generic = try? Base64.decode(NonContiguousBytes(storage: input), options: options)
        let fromSpan = try? SpanAccess.read(input) { try Base64.decode($0, options: options) }
        #expect(contiguous == expected, "contiguous \(label) \(input)")
        #expect(generic == expected, "generic \(label) \(input)")
        #expect(fromSpan == expected, "span \(label) \(input)")
        // Into a buffer of exactly the right size, and one byte short.
        if let expected {
            let exact = try? Base64.decodeCanary(input, capacity: expected.count, options: options)
            #expect(exact?.written == expected.count, "into \(label) \(input)")
            #expect(exact?.window == expected, "into \(label) \(input)")
            if !expected.isEmpty {
                let short = try? Base64.decodeCanary(input, capacity: expected.count - 1, options: options)
                #expect(short == nil, "short buffer \(label) \(input)")
            }
        }
    }

    // MARK: - Reference parity

    @Test func randomInputsAgreeWithTheReferenceForEveryLengthUpTo64() {
        var rng = SeededRNG(seed: Seed.named("base64.parity.random"))
        for length in 0 ... 64 {
            for _ in 0 ..< 60 {
                let options = Base64Generators.randomOptions(&rng)
                let input = Base64Generators.randomText(length, options, &rng)
                expectAgreement(input, options, label: "random")
            }
        }
    }

    @Test func validEncodingsAgreeWithTheReferenceAndRoundTrip() throws {
        var rng = SeededRNG(seed: Seed.named("base64.parity.valid"))
        for length in 0 ... 64 {
            for _ in 0 ..< 20 {
                let options = Base64Generators.randomOptions(&rng)
                let original = Base64Generators.randomBytes(length, &rng)
                let encoded = Base64.encode(original, options: options)
                #expect(encoded == ReferenceBase64.encode(original, options))
                expectAgreement(encoded, options, label: "valid")
                if options.maximumDecodedSize == nil || options.maximumDecodedSize.map({ $0 >= length }) == true {
                    if options.whitespace != .reject || !encoded.contains(0x0A) {
                        #expect(attempt(encoded, options) == original, "round trip")
                    }
                }
            }
        }
    }

    @Test func largeInputsAgreeWithTheReference() throws {
        var rng = SeededRNG(seed: Seed.named("base64.parity.large"))
        let original = Base64Generators.randomBytes(150_001, &rng)
        for options in [Base64.Options.strict, .urlSafeNoPadding, .pem, .mime] {
            let encoded = Base64.encode(original, options: options)
            #expect(encoded == ReferenceBase64.encode(original, options))
            #expect(try Base64.decode(encoded, options: options) == original)
            // One flipped byte in the middle is found by both paths at the same place.
            var broken = encoded
            broken[broken.count / 2] = UInt8(ascii: "*")
            #expect(attempt(broken, options) == nil)
            #expect(ReferenceBase64.decode(broken, options) == nil)
        }
    }

    // MARK: - Every option combination

    @Test func everyOptionCombinationRoundTripsOrFailsAtTheFirstLineBreak() throws {
        var rng = SeededRNG(seed: Seed.named("base64.combos"))
        var alphabets: [Base64.AlphabetTable] = [.standard, .urlSafe]
        alphabets.append(Base64Generators.customAlphabet(&rng))
        var combinations = 0
        for alphabet in alphabets {
            for padding in [Base64.PaddingPolicy.required, .optional, .forbidden, .tolerated] {
                for bits in [Base64.TrailingBitsPolicy.canonical, .lenient] {
                    for whitespace in [Base64.WhitespacePolicy.reject, .skipLineBreaks, .skipAll] {
                        for lineLength in [nil, 4, 7, 64] as [Int?] {
                            for ending in [Base64.LineEnding.lf, .crlf] {
                                let options = Base64.Options(
                                    alphabet: alphabet, padding: padding, trailingBits: bits,
                                    whitespace: whitespace, lineLength: lineLength, lineEnding: ending)
                                combinations += 1
                                try checkRoundTrip(options, rng: &rng)
                            }
                        }
                    }
                }
            }
        }
        #expect(combinations == 3 * 4 * 2 * 3 * 4 * 2)
    }

    private func checkRoundTrip(_ options: Base64.Options, rng: inout SeededRNG) throws {
        for length in [0, 1, 2, 3, 4, 5, 6, 7, 16, 47, 48, 49, 100] {
            let original = Base64Generators.randomBytes(length, &rng)
            let encoded = Base64.encode(original, options: options)
            #expect(options.encodedLength(forByteCount: length) == encoded.count)
            var thrown: Base64.DecodeError?
            var decoded: [UInt8]?
            do { decoded = try Base64.decode(encoded, options: options) } catch { thrown = error }
            if options.whitespace == .reject, let width = options.lineLength, encoded.count > width {
                // Wrapped output is not decodable when line breaks are not skipped.
                #expect(thrown == .invalidByte(options.lineEnding == .lf ? 0x0A : 0x0D, offset: width))
            } else {
                #expect(decoded == original, "\(options)")
            }
        }
    }

    // MARK: - The canonical-form guarantee

    @Test func strictAcceptsExactlyOneTextPerByteString() throws {
        // Exhaust every possible final group: a text strict accepts must be the encoding of what it decodes to.
        let symbols = Base64.AlphabetTable.standard.symbols
        let pad = UInt8(ascii: "=")
        var twoSymbolTails = 0
        for a in symbols {
            for b in symbols {
                let text = [a, b, pad, pad]
                if let decoded = attempt(text, .strict) {
                    twoSymbolTails += 1
                    #expect(Base64.encode(decoded, options: .strict) == text)
                }
            }
        }
        #expect(twoSymbolTails == 64 * 4)
        var threeSymbolTails = 0
        for a in symbols {
            for b in symbols {
                for c in symbols {
                    let text = [a, b, c, pad]
                    guard let decoded = attempt(text, .strict) else { continue }
                    threeSymbolTails += 1
                    #expect(Base64.encode(decoded, options: .strict) == text)
                }
            }
        }
        #expect(threeSymbolTails == 64 * 64 * 16)
    }

    @Test func strictAcceptsOnlyTheCanonicalEncodingOfRandomMutations() {
        var rng = SeededRNG(seed: Seed.named("base64.canonical.mutations"))
        for _ in 0 ..< 5_000 {
            let original = Base64Generators.randomBytes(rng.int(in: 0 ... 30), &rng)
            var text = Base64.encode(original, options: .strict)
            var mutator = ByteMutator()
            mutator.maxExtend = 4
            mutator.apply(rng.int(in: 1 ... 3), to: &text, using: &rng)
            if let decoded = attempt(text, .strict) {
                #expect(Base64.encode(decoded, options: .strict) == text, "accepted a non-canonical text")
            }
        }
    }

    // MARK: - Mutation fuzzing

    @Test(.tags(.fuzz)) func mutatedEncodingsNeverTrapAndAgreeWithTheReference() {
        for options in Base64Generators.presets {
            var seedRNG = SeededRNG(seed: Seed.named("base64.fuzz.corpus"))
            let corpus = Base64.encode(Base64Generators.randomBytes(150, &seedRNG), options: options)
            let report = fuzzNeverTraps(
                seed: Seed.named("base64.fuzz.\(options.lineLength ?? 0).\(options.padding)"),
                iterations: 1_500,
                corpus: { corpus },
                exercise: { mutated in
                    let expected = ReferenceBase64.decode(mutated, options)
                    #expect(attempt(mutated, options) == expected)
                    #expect((try? Base64.decode(NonContiguousBytes(storage: mutated), options: options)) == expected)
                    _ = try? Base64.decodeCanary(mutated, capacity: 5, options: options)  // must not overflow
                })
            #expect(report.iterations == 1_500)
        }
    }
}

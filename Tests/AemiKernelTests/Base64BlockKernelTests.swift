import AemiKernel
import AemiTestKit
import Testing

/// The NEON block kernels against the byte-at-a-time engine, which never uses them: the same result, and the same typed
/// error at the same offset, for every length around a block edge, a bad byte at every position, and output limits.
@Suite(.tags(.parity))
struct Base64BlockKernelTests {
    private func outcome(_ input: [UInt8], _ options: Base64.Options, contiguous: Bool) -> String {
        do {
            let bytes =
                contiguous
                ? try Base64.decode(input, options: options)
                : try Base64.decode(NonContiguousBytes(storage: input), options: options)
            return "ok \(bytes)"
        } catch {
            return "error \(error)"
        }
    }

    /// Standard and URL-safe, a shuffled one (x86-64 computes symbols only for `A-Za-z0-9` + two, so this one takes the scalar
    /// reference there and the `tbl` kernel on arm64), and `A-Za-z0-9` with two other symbols.
    private func alphabets(_ rng: inout SeededRNG) throws -> [Base64.AlphabetTable] {
        var ranged = Base64.AlphabetTable.standard.symbols
        ranged[62] = UInt8(ascii: "*")
        ranged[63] = UInt8(ascii: ",")
        return [
            .standard, .urlSafe, Base64Generators.customAlphabet(&rng), try Base64.AlphabetTable(symbols: ranged)
        ]
    }

    @Test func everyAlphabetShapeAgreesWithTheReferenceAndTheByteEngine() throws {
        var rng = SeededRNG(seed: Seed.named("base64.blocks.alphabets"))
        for table in try alphabets(&rng) {
            var options = Base64.Options.strict
            options.alphabet = table
            for length in 0 ... 200 {
                let bytes = Base64Generators.randomBytes(length, &rng)
                let encoded = Base64.encode(bytes, options: options)
                #expect(encoded == ReferenceBase64.encode(bytes, options), "encode \(length)")
                #expect(outcome(encoded, options, contiguous: true) == "ok \(bytes)", "decode \(length)")
                var broken = encoded
                if !broken.isEmpty {
                    broken[Int(rng.next() % UInt64(broken.count))] = UInt8(ascii: "!")
                    #expect(
                        outcome(broken, options, contiguous: true) == outcome(broken, options, contiguous: false),
                        "broken \(length)"
                    )
                }
            }
        }
    }

    @Test func encodeMatchesTheReferenceAroundEveryBlockEdge() {
        var rng = SeededRNG(seed: Seed.named("base64.blocks.encode"))
        for length in 0 ... 400 {
            let bytes = Base64Generators.randomBytes(length, &rng)
            for options in [Base64.Options.strict, .urlSafeNoPadding, .mime, .pem] {
                #expect(Base64.encode(bytes, options: options) == ReferenceBase64.encode(bytes, options), "\(length)")
            }
        }
    }

    @Test func aBadByteAtEveryPositionIsReportedLikeTheByteEngine() {
        var rng = SeededRNG(seed: Seed.named("base64.blocks.bad"))
        let options = [Base64.Options.strict, .urlSafeNoPadding, .pem, .lenient]
        let bad: [UInt8] = [
            UInt8(ascii: "*"), UInt8(ascii: "-"), UInt8(ascii: " "), 0x80, 0xFF, 0x00, UInt8(ascii: "=")
        ]
        for length in [48, 96, 144, 192, 300] {
            let original = Base64Generators.randomBytes(length, &rng)
            for option in options {
                let encoded = Base64.encode(original, options: option)
                for position in 0 ..< encoded.count {
                    var broken = encoded
                    broken[position] = bad[(position + length) % bad.count]
                    #expect(
                        outcome(broken, option, contiguous: true) == outcome(broken, option, contiguous: false),
                        "length \(length) position \(position)"
                    )
                }
            }
        }
    }

    @Test func outputLimitsAreReportedLikeTheByteEngine() throws {
        var rng = SeededRNG(seed: Seed.named("base64.blocks.limit"))
        let original = Base64Generators.randomBytes(400, &rng)
        var options = Base64.Options.strict
        let encoded = Base64.encode(original, options: options)
        for limit in stride(from: 0, through: 420, by: 7) {
            options.maximumDecodedSize = limit
            #expect(
                outcome(encoded, options, contiguous: true) == outcome(encoded, options, contiguous: false),
                "limit \(limit)"
            )
            var buffer = [UInt8](repeating: 0xAA, count: limit)
            let result = try? buffer.withUnsafeMutableBufferPointer {
                try Base64.decode(encoded, into: $0, options: .strict)
            }
            if limit >= original.count { #expect(result == original.count) } else { #expect(result == nil) }
        }
    }

    @Test func lineLimitsAreReportedLikeTheByteEngine() {
        var rng = SeededRNG(seed: Seed.named("base64.blocks.lines"))
        let original = Base64Generators.randomBytes(1_000, &rng)
        for width in [4, 60, 64, 68, 76, 80, 128, 200] {
            var options = Base64.Options.mime
            options.lineLength = width
            let encoded = Base64.encode(original, options: .mime)
            #expect(
                outcome(encoded, options, contiguous: true) == outcome(encoded, options, contiguous: false),
                "\(width)"
            )
        }
    }
}

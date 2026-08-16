import AemiKernels
import AemiTestKit
import Testing

// Differential / oracle tests: every kernel backend (forced) must agree byte-for-byte with an
// INDEPENDENT pure-Swift reference — across all 256 byte values at every lane/chunk offset, and over
// thousands of seeded-random inputs. Forced backends self-guard (fall back when their CPU feature is
// absent), so this whole suite runs on any host: on arm64 `.neon` exercises NEON while `.sse2`/`.avx2`
// fall to scalar; on x86 the reverse. Real AVX2/dotprod execution is validated on the Linux CI legs.
struct AemiKernelsTests {
    static let backends: [AemiKernels.Backend] = [.fastest, .scalar, .sse2, .avx2, .neon]

    // MARK: - Independent references

    static func referenceFold(_ bytes: [UInt8]) -> [UInt8] {
        bytes.map { byte in (byte >= 0x41 && byte <= 0x5A) ? (byte | 0x20) : byte }
    }

    static func referenceStop(_ bytes: [UInt8], _ quote: UInt8, _ escape: UInt8) -> Int? {
        for index in bytes.indices {
            let byte = bytes[index]
            if byte < 0x20 || byte >= 0x80 || byte == quote || byte == escape { return index }
        }
        return nil
    }

    static func referenceNonASCII(_ bytes: [UInt8]) -> Int? {
        for index in bytes.indices where bytes[index] >= 0x80 { return index }
        return nil
    }

    // MARK: - ASCII fold

    /// Every byte value, at every offset within a > 32-byte buffer (so both the 16- and 32-byte SIMD
    /// bodies and the scalar tail run), folds identically to the independent reference on every backend.
    @Test func foldMatchesReferenceEveryByteAndOffset() {
        var mismatches = 0
        for offset in 0 ..< 48 {
            for value in 0 ... 255 {
                var input = [UInt8](repeating: UInt8(ascii: "m"), count: 48)
                input[offset] = UInt8(value)
                let expected = Self.referenceFold(input)
                for backend in Self.backends where AemiKernels.foldedASCII(input, backend: backend) != expected {
                    mismatches += 1
                }
            }
        }
        #expect(mismatches == 0)
    }

    /// Random mixed inputs of varied length fold identically across all backends.
    @Test func foldFuzzed() {
        var rng = SeededRNG(seed: 0x8F41_2C7A_9B0D_1E63)
        var mismatches = 0
        for _ in 0 ..< 4000 {
            let count = rng.int(70)
            var input: [UInt8] = []
            input.reserveCapacity(count)
            for _ in 0 ..< count { input.append(UInt8(rng.int(256))) }
            let expected = Self.referenceFold(input)
            for backend in Self.backends where AemiKernels.foldedASCII(input, backend: backend) != expected {
                mismatches += 1
            }
        }
        #expect(mismatches == 0)
    }

    @Test func foldInPlaceEqualsCopy() {
        var buffer = Array("Hello, WORLD 123 ÀÉ".utf8)
        let expected = Self.referenceFold(buffer)
        buffer.withUnsafeMutableBufferPointer { storage in
            guard let base = storage.baseAddress else { return }
            AemiKernels.foldASCII(into: base, from: base, count: storage.count)
        }
        #expect(buffer == expected)
    }

    // MARK: - String-stop scan

    /// Every byte value, at every offset in a > 32-byte content buffer, yields the same first-stop
    /// index as the independent reference on every backend (exercises both SIMD bodies + the tail).
    @Test func stopMatchesReferenceEveryByteAndOffset() {
        let quote = UInt8(ascii: "\"")
        let escape = UInt8(ascii: "\\")
        var mismatches = 0
        for offset in 0 ..< 40 {
            for value in 0 ... 255 {
                var input = [UInt8](repeating: UInt8(ascii: "x"), count: 40)
                input[offset] = UInt8(value)
                let expected = Self.referenceStop(input, quote, escape)
                for backend in Self.backends
                where AemiKernels.indexOfStringStop(input, quote: quote, escape: escape, backend: backend) != expected {
                    mismatches += 1
                }
            }
        }
        #expect(mismatches == 0)
    }

    /// Custom quote/escape bytes are honored identically across backends (parameterization is real).
    @Test func stopHonorsCustomDelimiters() {
        let input = Array("field=value;more=data".utf8)
        let expected = Self.referenceStop(input, UInt8(ascii: "="), UInt8(ascii: ";"))
        var mismatches = 0
        for backend in Self.backends
        where AemiKernels.indexOfStringStop(input, quote: UInt8(ascii: "="), escape: UInt8(ascii: ";"), backend: backend)
            != expected
        {
            mismatches += 1
        }
        #expect(mismatches == 0)
        #expect(expected == 5)  // first '=' at index 5
    }

    @Test func stopFuzzed() {
        var rng = SeededRNG(seed: 0x2D9A_74E1_C305_88BF)
        let quote = UInt8(ascii: "\"")
        let escape = UInt8(ascii: "\\")
        var mismatches = 0
        for _ in 0 ..< 4000 {
            let count = rng.int(80)
            var input: [UInt8] = []
            input.reserveCapacity(count)
            // Bias toward plain ASCII content so long clean runs (the vector fast-forward) dominate,
            // with occasional specials to exercise the precise-locate path.
            for _ in 0 ..< count {
                input.append(rng.int(4) == 0 ? UInt8(rng.int(256)) : UInt8(0x20 + rng.int(0x5F)))
            }
            let expected = Self.referenceStop(input, quote, escape)
            for backend in Self.backends
            where AemiKernels.indexOfStringStop(input, quote: quote, escape: escape, backend: backend) != expected {
                mismatches += 1
            }
        }
        #expect(mismatches == 0)
    }

    // MARK: - Single-byte search

    @Test func byteSearchMatchesReference() {
        var rng = SeededRNG(seed: 0x51C7_0FA2_66E3_49D1)
        var mismatches = 0
        for _ in 0 ..< 3000 {
            let count = rng.int(64)
            var input: [UInt8] = []
            input.reserveCapacity(count)
            for _ in 0 ..< count { input.append(UInt8(rng.int(16))) }  // small alphabet ⇒ frequent hits
            let needle = UInt8(rng.int(16))
            let expected = input.firstIndex(of: needle)
            let fast = AemiKernels.firstIndexOfByte(needle, in: input, backend: .fastest)
            let scalar = AemiKernels.firstIndexOfByte(needle, in: input, backend: .scalar)
            if fast != expected || scalar != expected { mismatches += 1 }
        }
        #expect(mismatches == 0)
    }

    // MARK: - First byte in a small literal set

    @Test func anyMatchesReferenceEveryByteAndOffset() {
        let needles: [UInt8] = [0x26, 0x3C, 0x3E, 0x22, 0x27]  // & < > " '  (HTML escape set)
        var mismatches = 0
        for offset in 0 ..< 40 {
            for value in 0 ... 255 {
                var input = [UInt8](repeating: UInt8(ascii: "a"), count: 40)
                input[offset] = UInt8(value)
                let expected: Int? = input.firstIndex { needles.contains($0) }
                input.withUnsafeBufferPointer { buffer in
                    guard let base = buffer.baseAddress else { return }
                    for backend in [AemiKernels.Backend.fastest, .scalar] {
                        let index = AemiKernels.firstIndexOfAny(
                            base: base, count: 40,
                            needles[0], needles[1], needles[2], needles[3], needles[4], backend: backend)
                        if (index == 40 ? nil : index) != expected { mismatches += 1 }
                    }
                }
            }
        }
        #expect(mismatches == 0)
    }

    // MARK: - First non-ASCII byte

    @Test func nonASCIIMatchesReferenceEveryByteAndOffset() {
        var mismatches = 0
        for offset in 0 ..< 40 {
            for value in 0 ... 255 {
                var input = [UInt8](repeating: UInt8(ascii: "a"), count: 40)
                input[offset] = UInt8(value)
                let expected = Self.referenceNonASCII(input)
                for backend in Self.backends
                where AemiKernels.firstNonASCII(input, backend: backend) != expected {
                    mismatches += 1
                }
            }
        }
        #expect(mismatches == 0)
    }

    // MARK: - Printable-text validation

    @Test func disallowedTextMatchesReference() {
        func reference(_ bytes: [UInt8], _ minAllowed: UInt8, _ allowTab: Bool) -> Int? {
            for index in bytes.indices {
                let byte = bytes[index]
                if byte >= 0x80 { continue }
                if byte == 0x7F { return index }
                if byte < minAllowed, !(allowTab && byte == 0x09) { return index }
            }
            return nil
        }
        var mismatches = 0
        let configs: [(UInt8, Bool)] = [(0x20, true), (0x21, false)]  // field-value, request-target
        for (minAllowed, allowTab) in configs {
            for offset in 0 ..< 40 {
                for value in 0 ... 255 {
                    var input = [UInt8](repeating: UInt8(ascii: "a"), count: 40)
                    input[offset] = UInt8(value)
                    let expected = reference(input, minAllowed, allowTab)
                    input.withUnsafeBufferPointer { buffer in
                        guard let base = buffer.baseAddress else { return }
                        for backend in [AemiKernels.Backend.fastest, .scalar] {
                            let index = AemiKernels.firstDisallowedText(
                                base: base, count: 40, minAllowed: minAllowed, allowTab: allowTab,
                                backend: backend)
                            if (index == 40 ? nil : index) != expected { mismatches += 1 }
                        }
                    }
                }
            }
        }
        #expect(mismatches == 0)
    }

    // MARK: - First control byte or literal

    @Test func controlOrAnyMatchesReference() {
        let needles: [UInt8] = [0x22, 0x5C, 0x2F, 0x22, 0x22]  // " \ /  (JSON escape-on-write set)
        var mismatches = 0
        for offset in 0 ..< 40 {
            for value in 0 ... 255 {
                var input = [UInt8](repeating: UInt8(ascii: "a"), count: 40)
                input[offset] = UInt8(value)
                let expected: Int? = input.firstIndex { $0 < 0x20 || needles.contains($0) }
                input.withUnsafeBufferPointer { buffer in
                    guard let base = buffer.baseAddress else { return }
                    for backend in [AemiKernels.Backend.fastest, .scalar] {
                        let index = AemiKernels.indexOfControlOrAny(
                            base: base, count: 40,
                            needles[0], needles[1], needles[2], needles[3], needles[4], backend: backend)
                        if (index == 40 ? nil : index) != expected { mismatches += 1 }
                    }
                }
            }
        }
        #expect(mismatches == 0)
    }

    // MARK: - Detection

    @Test func activeBackendIsNamed() {
        let name = AemiKernels.activeBackend
        #expect(!name.isEmpty)
        let known = ["scalar", "sse2", "sse4.2", "avx2", "avx512", "neon", "neon+dotprod", "neon+i8mm"]
        #expect(known.contains(name))
    }
}

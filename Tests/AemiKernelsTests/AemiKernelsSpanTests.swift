import AemiKernels
import AemiTestKit
import Testing

// The `RawSpan` overloads read borrowed bytes in place instead of taking an array. Each must agree with
// its `[UInt8]` sibling (itself checked against the independent references in AemiKernelsTests) on
// every backend, over seeded inputs of every length from empty up, mostly plain ASCII so the scans run
// long, with stray bytes of any value (controls, quotes, NUL, non-ASCII, broken UTF-8) mixed in.
struct AemiKernelsSpanTests {
    static let backends: [AemiKernels.Backend] = [.fastest, .scalar, .sse2, .avx2, .neon]

    static let inputs: [ContiguousArray<UInt8>] = {
        var rng = SeededRNG(seed: 0x5BA2_0D17_A11C_0DE5)
        var inputs: [ContiguousArray<UInt8>] = []
        for index in 0 ..< 600 {
            let count = index < 70 ? index : rng.int(300)
            var bytes = ContiguousArray<UInt8>()
            bytes.reserveCapacity(count)
            for _ in 0 ..< count {
                bytes.append(rng.int(8) == 0 ? UInt8(rng.int(256)) : 0x61 + UInt8(rng.int(26)))
            }
            inputs.append(bytes)
        }
        return inputs
    }()

    @Test func `foldedASCII over a span matches the array overload`() {
        var mismatches = 0
        for input in Self.inputs {
            let array = Array(input)
            for backend in Self.backends
            where AemiKernels.foldedASCII(input.span.bytes, backend: backend)
                != AemiKernels.foldedASCII(array, backend: backend)
            {
                mismatches += 1
            }
        }
        #expect(mismatches == 0)
    }

    @Test func `indexOfStringStop over a span matches the array overload`() {
        var mismatches = 0
        for input in Self.inputs {
            let array = Array(input)
            for backend in Self.backends
            where AemiKernels.indexOfStringStop(input.span.bytes, quote: 0x22, escape: 0x5C, backend: backend)
                != AemiKernels.indexOfStringStop(array, quote: 0x22, escape: 0x5C, backend: backend)
            {
                mismatches += 1
            }
        }
        #expect(mismatches == 0)
    }

    @Test func `firstIndexOfByte over a span matches the array overload`() {
        var mismatches = 0
        for input in Self.inputs {
            let array = Array(input)
            for needle: UInt8 in [0x00, 0x2C, 0x7A] {
                for backend in [AemiKernels.Backend.fastest, .scalar]
                where AemiKernels.firstIndexOfByte(needle, in: input.span.bytes, backend: backend)
                    != AemiKernels.firstIndexOfByte(needle, in: array, backend: backend)
                {
                    mismatches += 1
                }
            }
        }
        #expect(mismatches == 0)
    }

    @Test func `firstInvalidUTF8 over a span matches the array overload`() {
        var mismatches = 0
        for input in Self.inputs {
            let array = Array(input)
            for backend in [AemiKernels.Backend.fastest, .scalar]
            where AemiKernels.firstInvalidUTF8(input.span.bytes, backend: backend)
                != AemiKernels.firstInvalidUTF8(array, backend: backend)
            {
                mismatches += 1
            }
        }
        #expect(mismatches == 0)
    }

    @Test func `firstNonASCII over a span matches the array overload`() {
        var mismatches = 0
        for input in Self.inputs {
            let array = Array(input)
            for backend in Self.backends
            where AemiKernels.firstNonASCII(input.span.bytes, backend: backend)
                != AemiKernels.firstNonASCII(array, backend: backend)
            {
                mismatches += 1
            }
        }
        #expect(mismatches == 0)
    }
}

import AemiKernels
import AemiTestKit
import Testing

// Robustness surface for the SIMD kernels, beyond the all-256×offsets differential in AemiKernelsTests:
//   1. Boundary SIZES — every buffer length around the 16/32-byte SIMD bodies and the scalar tail, with
//      the target byte at the first / last / no position (guards off-by-one in the chunk/tail seams).
//   2. Property INVARIANTS — for each find-first kernel: result ∈ 0...count; the byte AT the result
//      satisfies the predicate; NO byte before it does. Catches "plausible but wrong" results without a
//      scalar oracle (defense in depth over the differential checks).
//   3. Randomized differential FUZZ — many seeded-random inputs over adversarial byte distributions,
//      asserting every backend agrees with the scalar reference. (The coverage-guided libFuzzer target
//      `AemiKernelsFuzz` runs the same contract on Linux CI; this is the macOS-runnable form.)
// Run under AddressSanitizer (`swift test --sanitize=address`) to prove the SIMD loads never over-read.
struct AemiKernelsRobustnessTests {
    // MARK: - Kernel descriptors: (run-all-backends closure, per-byte predicate) for the find-first kernels.

    /// A find-first kernel under test: its name, the backends it distinguishes, an invoker that returns
    /// the index for a given buffer + backend, and the per-byte predicate the index must satisfy.
    struct Kernel: Sendable {
        let name: String
        let backends: [AemiKernels.Backend]
        let run: @Sendable (UnsafePointer<UInt8>, Int, AemiKernels.Backend) -> Int
        let predicate: @Sendable (UInt8) -> Bool
    }

    static let quote = UInt8(ascii: "\"")
    static let escape = UInt8(ascii: "\\")

    static let findFirstKernels: [Kernel] = [
        Kernel(
            name: "indexOfStringStop",
            backends: [.fastest, .scalar, .sse2, .avx2, .neon],
            run: { base, count, backend in
                AemiKernels.indexOfStringStop(
                    base: base, count: count, quote: quote, escape: escape, backend: backend)
            },
            predicate: { $0 < 0x20 || $0 >= 0x80 || $0 == quote || $0 == escape }),
        Kernel(
            name: "firstNonASCII",
            backends: [.fastest, .scalar, .sse2, .avx2, .neon],
            run: { base, count, backend in
                AemiKernels.firstNonASCII(base: base, count: count, backend: backend)
            },
            predicate: { $0 >= 0x80 }),
        Kernel(
            name: "firstIndexOfByte",
            backends: [.fastest, .scalar],
            run: { base, count, backend in
                AemiKernels.firstIndexOfByte(base: base, count: count, needle: 0x2C, backend: backend)
            },
            predicate: { $0 == 0x2C }),
        Kernel(
            name: "firstIndexOfAny",
            backends: [.fastest, .scalar],
            run: { base, count, backend in
                AemiKernels.firstIndexOfAny(
                    base: base, count: count, 0x26, 0x3C, 0x3E, 0x22, 0x27, backend: backend)
            },
            predicate: { $0 == 0x26 || $0 == 0x3C || $0 == 0x3E || $0 == 0x22 || $0 == 0x27 }),
        Kernel(
            name: "indexOfControlOrAny",
            backends: [.fastest, .scalar],
            run: { base, count, backend in
                AemiKernels.indexOfControlOrAny(
                    base: base, count: count, 0x22, 0x5C, 0x2F, 0x22, 0x22, backend: backend)
            },
            predicate: { $0 < 0x20 || $0 == 0x22 || $0 == 0x5C || $0 == 0x2F }),
        Kernel(
            name: "firstDisallowedText(field-value)",
            backends: [.fastest, .scalar],
            run: { base, count, backend in
                AemiKernels.firstDisallowedText(
                    base: base, count: count, minAllowed: 0x20, allowTab: true, backend: backend)
            },
            predicate: { $0 < 0x80 && ($0 == 0x7F || ($0 < 0x20 && $0 != 0x09)) }),
        Kernel(
            name: "firstDisallowedText(request-target)",
            backends: [.fastest, .scalar],
            run: { base, count, backend in
                AemiKernels.firstDisallowedText(
                    base: base, count: count, minAllowed: 0x21, allowTab: false, backend: backend)
            },
            predicate: { $0 < 0x80 && ($0 == 0x7F || $0 <= 0x20) })
    ]

    static let boundarySizes = [0, 1, 2, 7, 8, 15, 16, 17, 30, 31, 32, 33, 47, 48, 63, 64, 65, 96, 128, 200]

    // MARK: - 1. Boundary sizes × target position

    /// For each kernel and each boundary size, plant a matching byte at the first / last / no position
    /// and check every backend agrees with the scalar reference (and with a from-scratch scan).
    @Test func boundarySizesAndPositions() {
        var mismatches = 0
        let filler = UInt8(ascii: "a")  // never matches any kernel's predicate
        // A byte that DOES satisfy each predicate: control 0x01 satisfies stop/control/disallowed;
        // for the others we plant the specific matching byte. Use a per-kernel matcher.
        for kernel in Self.findFirstKernels {
            // A concrete matching byte for this kernel (first byte in 0...255 that satisfies it).
            let match = (UInt8.min ... UInt8.max).first { kernel.predicate($0) } ?? 0x01
            for size in Self.boundarySizes {
                for planted in plantedPositions(size) {
                    var bytes = [UInt8](repeating: filler, count: size)
                    if let position = planted { bytes[position] = match }
                    let reference = bytes.firstIndex { kernel.predicate($0) } ?? size
                    bytes.withUnsafeBufferPointer { buffer in
                        let base = buffer.baseAddress ?? emptyBase
                        for backend in kernel.backends
                        where kernel.run(base, size, backend) != reference {
                            mismatches += 1
                        }
                    }
                }
            }
        }
        #expect(mismatches == 0)
    }

    /// Positions to plant the matching byte for a buffer of `size`: none, first, last, and a mid point.
    private func plantedPositions(_ size: Int) -> [Int?] {
        guard size > 0 else { return [nil] }
        return [nil, 0, size - 1, size / 2]
    }

    // A stable non-nil base for the empty buffer (never dereferenced — count is 0).
    private var emptyBase: UnsafePointer<UInt8> {
        UnsafePointer(bitPattern: 0x1000).unsafelyUnwrapped
    }

    // MARK: - 2. Property invariants (no oracle needed)

    @Test func findFirstInvariants() {
        var rng = SeededRNG(seed: 0x9E37_79B9_7F4A_7C15)
        var violations = 0
        for _ in 0 ..< 3000 {
            let bytes = Self.randomBuffer(&rng)
            for kernel in Self.findFirstKernels {
                bytes.withUnsafeBufferPointer { buffer in
                    guard let base = buffer.baseAddress else { return }
                    let count = buffer.count
                    let result = kernel.run(base, count, .fastest)
                    // (a) in range.
                    if result < 0 || result > count {
                        violations += 1
                        return
                    }
                    // (b) the byte AT the result satisfies the predicate (unless no match).
                    if result < count, !kernel.predicate(buffer[result]) { violations += 1 }
                    // (c) no earlier byte satisfies the predicate.
                    for index in 0 ..< result where kernel.predicate(buffer[index]) {
                        violations += 1
                        break
                    }
                }
            }
        }
        #expect(violations == 0)
    }

    // MARK: - 3. Randomized differential fuzz (all backends vs scalar) + foldASCII

    @Test func randomizedDifferentialFuzz() {
        var rng = SeededRNG(seed: 0x2545_F491_4F6C_DD1D)
        var mismatches = 0
        for _ in 0 ..< 6000 {
            let bytes = Self.randomBuffer(&rng)
            // Every find-first kernel: all its backends must agree with its `.scalar` backend.
            for kernel in Self.findFirstKernels {
                bytes.withUnsafeBufferPointer { buffer in
                    let base = buffer.baseAddress ?? self.emptyBase
                    let count = buffer.count
                    let reference = kernel.run(base, count, .scalar)
                    for backend in kernel.backends where kernel.run(base, count, backend) != reference {
                        mismatches += 1
                    }
                }
            }
            // foldASCII (transform): every backend must equal the scalar backend.
            let foldReference = AemiKernels.foldedASCII(bytes, backend: .scalar)
            for backend in [AemiKernels.Backend.fastest, .sse2, .avx2, .neon]
            where AemiKernels.foldedASCII(bytes, backend: backend) != foldReference {
                mismatches += 1
            }
        }
        #expect(mismatches == 0)
    }

    /// Adversarial byte distributions across varied lengths (incl. 0 and boundary sizes): all-ASCII,
    /// control-heavy, non-ASCII-heavy, delimiter-heavy, and fully uniform-random.
    static func randomBuffer(_ rng: inout SeededRNG) -> [UInt8] {
        let sizePool = boundarySizes + [rng.int(260)]
        let count = sizePool[rng.int(sizePool.count)]
        guard count > 0 else { return [] }
        let mode = rng.int(5)
        var out: [UInt8] = []
        out.reserveCapacity(count)
        for _ in 0 ..< count {
            switch mode {
                case 0: out.append(UInt8(0x20 + rng.int(0x5F)))  // printable ASCII
                case 1: out.append(UInt8(rng.int(0x20)))  // control-heavy
                case 2: out.append(UInt8(0x80 + rng.int(0x80)))  // non-ASCII-heavy
                case 3:  // delimiter-heavy (the kernels' needles + control + DEL)
                    let pool: [UInt8] = [0x22, 0x5C, 0x2F, 0x26, 0x3C, 0x3E, 0x27, 0x2C, 0x09, 0x7F, 0x61, 0x80]
                    out.append(pool[rng.int(pool.count)])
                default: out.append(UInt8(rng.int(256)))  // uniform random
            }
        }
        return out
    }
}

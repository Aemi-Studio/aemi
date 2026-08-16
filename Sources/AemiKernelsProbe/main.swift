//
//  main.swift
//  AemiKernelsProbe
//
//  A standalone, dependency-light differential check for the AemiKernels SIMD backends — the same
//  "every backend agrees with an independent scalar reference" oracle as `AemiKernelsTests`, but as a
//  plain executable instead of an xctest bundle. This is how the x86_64 slice is validated at RUNTIME
//  on an Apple-Silicon dev box: `swift build --arch x86_64 --product AemiKernelsProbe` then run the
//  binary — it executes under Rosetta 2 (exercising the real SSE2 path; AVX2 self-guards off), which
//  the in-process `swift test` loader cannot do cross-arch. Also the per-arch CI smoke check: it prints
//  the selected ISA tier and exits non-zero on any mismatch.
//

import AemiKernels

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

// Deterministic xorshift64 — no test-kit dependency, so the probe stays a leaf executable.
struct XorShift64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
    mutating func int(_ upperExclusive: Int) -> Int {
        upperExclusive <= 0 ? 0 : Int(next() % UInt64(upperExclusive))
    }
}

func referenceFold(_ bytes: [UInt8]) -> [UInt8] {
    bytes.map { byte in (byte >= 0x41 && byte <= 0x5A) ? (byte | 0x20) : byte }
}

func referenceStop(_ bytes: [UInt8], _ quote: UInt8, _ escape: UInt8) -> Int? {
    for index in bytes.indices {
        let byte = bytes[index]
        if byte < 0x20 || byte >= 0x80 || byte == quote || byte == escape { return index }
    }
    return nil
}

// MARK: - Throughput mode (`--bench`): scalar reference vs runtime-dispatched, on this host's ISA.

nonisolated(unsafe) var sink = 0

func timeNanosPerOp(_ iterations: Int, _ body: () -> Void) -> Double {
    let clock = ContinuousClock()
    let start = clock.now
    for _ in 0 ..< iterations { body() }
    let elapsed = clock.now - start
    let (seconds, attoseconds) = elapsed.components
    let totalNanos = Double(seconds) * 1_000_000_000 + Double(attoseconds) / 1_000_000_000
    return totalNanos / Double(iterations)
}

func report(_ label: String, bytes: Int, scalarNanos: Double, fastestNanos: Double) {
    let scalarMBs = Int(Double(bytes) * 1000.0 / scalarNanos)
    let fastestMBs = Int(Double(bytes) * 1000.0 / fastestNanos)
    let speedup = Double(Int((scalarNanos / fastestNanos) * 100)) / 100
    print(
        "bench \(label) n=\(bytes): scalar=\(Int(scalarNanos))ns (\(scalarMBs) MB/s)  "
            + "fastest=\(Int(fastestNanos))ns (\(fastestMBs) MB/s)  speedup=\(speedup)x")
}

func runBench() {
    let n = 1 << 16  // 64 KiB — long runs, where the vector fast-forward dominates.
    var content: [UInt8] = []
    let unit = Array("The Quick Brown Fox jumps 0123 ".utf8)
    while content.count < n { content += unit }
    content = Array(content.prefix(n))
    let quote = UInt8(ascii: "\"")
    let escape = UInt8(ascii: "\\")
    var foldOut = [UInt8](repeating: 0, count: n)
    let iterations = 5000

    print("AemiKernelsProbe --bench backend=\(AemiKernels.activeBackend)")
    content.withUnsafeBufferPointer { src in
        guard let base = src.baseAddress else { return }
        foldOut.withUnsafeMutableBufferPointer { dst in
            guard let out = dst.baseAddress else { return }
            for _ in 0 ..< 300 {  // warmup
                sink &+= AemiKernels.indexOfStringStop(
                    base: base, count: n, quote: quote, escape: escape, backend: .fastest)
                AemiKernels.foldASCII(into: out, from: base, count: n, backend: .fastest)
            }
            let stopScalar = timeNanosPerOp(iterations) {
                sink &+= AemiKernels.indexOfStringStop(
                    base: base, count: n, quote: quote, escape: escape, backend: .scalar)
            }
            let stopFastest = timeNanosPerOp(iterations) {
                sink &+= AemiKernels.indexOfStringStop(
                    base: base, count: n, quote: quote, escape: escape, backend: .fastest)
            }
            report("string-stop", bytes: n, scalarNanos: stopScalar, fastestNanos: stopFastest)
            let foldScalar = timeNanosPerOp(iterations) {
                AemiKernels.foldASCII(into: out, from: base, count: n, backend: .scalar)
            }
            let foldFastest = timeNanosPerOp(iterations) {
                AemiKernels.foldASCII(into: out, from: base, count: n, backend: .fastest)
            }
            report("fold", bytes: n, scalarNanos: foldScalar, fastestNanos: foldFastest)
        }
    }
    print("(sink=\(sink))")
}

if CommandLine.arguments.contains("--bench") {
    runBench()
    exit(0)
}

let backends: [AemiKernels.Backend] = [.fastest, .scalar, .sse2, .avx2, .neon]
let quote = UInt8(ascii: "\"")
let escape = UInt8(ascii: "\\")
var checks = 0
var failures = 0

// All 256 byte values at every offset across the 16/32-byte SIMD bodies + tail — fold and stop.
for offset in 0 ..< 48 {
    for value in 0 ... 255 {
        var foldInput = [UInt8](repeating: UInt8(ascii: "m"), count: 48)
        foldInput[offset] = UInt8(value)
        let foldExpected = referenceFold(foldInput)

        var stopInput = [UInt8](repeating: UInt8(ascii: "x"), count: 48)
        stopInput[offset] = UInt8(value)
        let stopExpected = referenceStop(stopInput, quote, escape)

        for backend in backends {
            checks += 2
            if AemiKernels.foldedASCII(foldInput, backend: backend) != foldExpected { failures += 1 }
            if AemiKernels.indexOfStringStop(stopInput, quote: quote, escape: escape, backend: backend)
                != stopExpected
            {
                failures += 1
            }
        }
    }
}

// Seeded-random mixed inputs of varied length.
var rng = XorShift64(state: 0x1234_5678_9ABC_DEF1)
for _ in 0 ..< 6000 {
    let count = rng.int(90)
    var input: [UInt8] = []
    input.reserveCapacity(count)
    for _ in 0 ..< count {
        input.append(rng.int(4) == 0 ? UInt8(rng.int(256)) : UInt8(0x20 + rng.int(0x5F)))
    }
    let foldExpected = referenceFold(input)
    let stopExpected = referenceStop(input, quote, escape)
    let byteNeedle = UInt8(rng.int(128))
    let byteExpected = input.firstIndex(of: byteNeedle)
    for backend in backends {
        checks += 3
        if AemiKernels.foldedASCII(input, backend: backend) != foldExpected { failures += 1 }
        if AemiKernels.indexOfStringStop(input, quote: quote, escape: escape, backend: backend)
            != stopExpected
        {
            failures += 1
        }
        if AemiKernels.firstIndexOfByte(byteNeedle, in: input, backend: backend) != byteExpected {
            failures += 1
        }
    }
    // Runtime-exercise the newer kernels: firstNonASCII, firstIndexOfAny (HTML set), firstDisallowedText
    // (field-value config), indexOfControlOrAny (JSON escape set).
    let nonAsciiExpected = input.firstIndex { $0 >= 0x80 }
    let anyExpected = input.firstIndex { $0 == 0x26 || $0 == 0x3C || $0 == 0x3E || $0 == 0x22 || $0 == 0x27 }
    let controlOrAnyExpected = input.firstIndex { $0 < 0x20 || $0 == 0x22 || $0 == 0x5C || $0 == 0x2F }
    var disallowedExpected: Int?
    for i in input.indices {
        let x = input[i]
        if x >= 0x80 { continue }
        if x == 0x7F || (x < 0x20 && x != 0x09) {
            disallowedExpected = i
            break
        }
    }
    checks += 5
    if AemiKernels.firstNonASCII(input) != nonAsciiExpected { failures += 1 }
    input.withUnsafeBufferPointer { buffer in
        guard let base = buffer.baseAddress else { return }
        let n = input.count
        let any = AemiKernels.firstIndexOfAny(base: base, count: n, 0x26, 0x3C, 0x3E, 0x22, 0x27)
        if (any == n ? nil : any) != anyExpected { failures += 1 }
        let coa = AemiKernels.indexOfControlOrAny(base: base, count: n, 0x22, 0x5C, 0x2F, 0x22, 0x22)
        if (coa == n ? nil : coa) != controlOrAnyExpected { failures += 1 }
        let dt = AemiKernels.firstDisallowedText(base: base, count: n, minAllowed: 0x20, allowTab: true)
        if (dt == n ? nil : dt) != disallowedExpected { failures += 1 }
        // firstInvalidUTF8: SIMD (SSE under Rosetta / NEON native) vs scalar oracle.
        if AemiKernels.firstInvalidUTF8(base: base, count: n)
            != AemiKernels.firstInvalidUTF8(base: base, count: n, backend: .scalar)
        {
            failures += 1
        }
    }
}

// A dedicated valid-multibyte pass so the SSE/NEON UTF-8 validator's accept path is exercised too.
do {
    let unit = Array("café 日本語 😀 résumé ".utf8)
    for reps in 1 ... 400 {
        var bytes: [UInt8] = []
        for _ in 0 ..< reps { bytes += unit }
        checks += 1
        let fast = AemiKernels.firstInvalidUTF8(bytes, backend: .fastest)
        let scalar = AemiKernels.firstInvalidUTF8(bytes, backend: .scalar)
        if fast != nil || scalar != nil { failures += 1 }
    }
}

// Hamming distance (NEON cnt / x86 POPCNT) vs an independent per-byte-popcount reference, incl. the
// 64-byte embedding width the semantic-search KNN scan uses.
do {
    var hrng = XorShift64(state: 0x2545_F491_4F6C_DD1D)
    let widths = [1, 8, 16, 64, 100, 257]
    for _ in 0 ..< 3000 {
        let width = widths[hrng.int(widths.count)]
        var a: [UInt8] = []
        var b: [UInt8] = []
        for _ in 0 ..< width {
            a.append(UInt8(hrng.int(256)))
            b.append(UInt8(hrng.int(256)))
        }
        var reference = 0
        for i in 0 ..< width { reference += Int((a[i] ^ b[i]).nonzeroBitCount) }
        checks += 2
        let fast: Int = a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                guard let ba = pa.baseAddress, let bb = pb.baseAddress else { return 0 }
                return AemiKernels.hammingDistance(ba, bb, count: width)
            }
        }
        let scalar: Int = a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                guard let ba = pa.baseAddress, let bb = pb.baseAddress else { return 0 }
                return AemiKernels.hammingDistance(ba, bb, count: width, backend: .scalar)
            }
        }
        if fast != reference { failures += 1 }
        if scalar != reference { failures += 1 }
    }
}

print("AemiKernelsProbe backend=\(AemiKernels.activeBackend) checks=\(checks) failures=\(failures)")
if failures == 0 {
    print("RESULT: PASS")
} else {
    print("RESULT: FAIL")
    exit(1)
}

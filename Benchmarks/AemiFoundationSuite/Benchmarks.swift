import AemiFileSystem
import AemiInterner
import AemiKernel
import AemiKernels
import AemiText
import Benchmark
import Dispatch
import Foundation

// AemiFoundation's benchmark suite on ordo-one's `Benchmark` framework, matching the sibling packages.
// Run with `AEMI_DEV=1 swift package benchmark` (add `BENCHMARK_DISABLE_JEMALLOC=1` if jemalloc isn't
// installed; CI installs it for malloc metrics). Each adaptive primitive's variants sit side by side
// so their p-percentiles are directly comparable — this is what backs the dispatch thresholds
// (`AemiText.bandedMinRowWidth`, `UTF8Validation.simdMinBytes`).

private func nearStrings(_ n: Int, edits k: Int) -> (a: [UInt8], b: [UInt8]) {
    let a = (0 ..< n).map { UInt8(97 + ($0 % 5)) }
    var b = a
    let stride = Swift.max(1, n / Swift.max(k, 1))
    for e in 0 ..< k {
        let i = (e * stride) % n
        b[i] = b[i] == 122 ? 97 : b[i] &+ 1
    }
    return (a, b)
}

private func asciiBytes(_ n: Int) -> [UInt8] { [UInt8](repeating: UInt8(ascii: "a"), count: n) }

// Realistic plain ASCII string content (mixed case + digits + spaces, no quote/backslash/control/
// non-ASCII), so `foldASCII` lowercases a fraction and `indexOfStringStop` scans the full length —
// the worst case for scalar and the best case for the SIMD fast-forward.
private func contentBytes(_ n: Int) -> [UInt8] {
    var out: [UInt8] = []
    let unit = Array("The Quick Brown Fox jumps 0123 ".utf8)
    while out.count < n { out += unit }
    return Array(out.prefix(n))
}

private func mixedBytes(_ n: Int) -> [UInt8] {
    var out: [UInt8] = []
    let unit = Array("aé本x".utf8)
    while out.count < n { out += unit }
    return out
}

// The allocating shape `NumberParse.doublePrefix` had before it was consolidated onto the shared
// `DecimalFloat` Clinger kernel: ~5 heap arrays + a `String` + `Double(String)` per call. Kept only to
// benchmark the new allocation-free path against it side by side (like the edit-distance variants), so
// the wall-clock speedup and the `.mallocCountTotal` drop are both visible in one report.
private func naiveDoublePrefix(_ s: [UInt8]) -> Double? {
    var t = s[...]
    func isWS(_ b: UInt8) -> Bool { b == 0x20 || (b >= 0x09 && b <= 0x0D) }
    while let f = t.first, isWS(f) { t = t.dropFirst() }
    var captured: [UInt8] = []
    if let f = t.first, f == 0x2B || f == 0x2D {
        if f == 0x2D { captured.append(f) }
        t = t.dropFirst()
    }
    var intDigits: [UInt8] = []
    while let b = t.first, b >= 0x30, b <= 0x39 {
        intDigits.append(b)
        t = t.dropFirst()
    }
    var frac: [UInt8] = []
    if t.first == 0x2E {
        t = t.dropFirst()
        while let b = t.first, b >= 0x30, b <= 0x39 {
            frac.append(b)
            t = t.dropFirst()
        }
    }
    guard !(intDigits.isEmpty && frac.isEmpty) else { return nil }
    captured.append(contentsOf: intDigits.isEmpty ? [0x30] : intDigits)
    if !frac.isEmpty {
        captured.append(0x2E)
        captured.append(contentsOf: frac)
    }
    return Double(String(decoding: captured, as: UTF8.self))
}

// The per-shift `append` loop the wire/disk framers hand-rolled before consolidating onto the
// `appendLE*` single-copy helpers — eight bounds-checked `append`s per `UInt64`. Kept only to
// benchmark the consolidated path against it side by side, so the wall-clock win is visible in one
// report (the malloc profile is held flat by `reserveCapacity` in both arms).
private func naiveAppendLE64(_ value: UInt64, to out: inout [UInt8]) {
    var shifted = value
    for _ in 0 ..< 8 {
        out.append(UInt8(truncatingIfNeeded: shifted))
        shifted >>= 8
    }
}

// The per-`Character` `String +=` escaper the SVG/XML builders hand-rolled before consolidating onto
// the byte-level `XMLEscape`. Foundation-free (no `replacingOccurrences`), kept only to benchmark the
// consolidated path against it side by side (wall-clock + `.mallocCountTotal`).
private func naiveXMLEscape(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.count)
    for ch in s {
        switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.append(ch)
        }
    }
    return out
}

/// A source-like tree under the temporary directory: `width` packages of `depth` nested directories, three files each,
/// for the directory-walk benchmarks (ADR 0017). Built once per process.
private let walkTree: String = {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("aemi-walk-bench").path
    try? FileManager.default.removeItem(atPath: root)
    for package in 0 ..< 40 {
        var directory = root + "/Package\(package)/Sources"
        for level in 0 ..< 8 {
            directory += "/Level\(level)"
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            for file in ["A.swift", "B.swift", "README.md"] {
                FileManager.default.createFile(atPath: directory + "/" + file, contents: Data())
            }
        }
    }
    return root
}()

/// Today's walk in analyzerkit's `SourceDiscovery`: a listing and an attributes dictionary per entry.
private func foundationWalk(_ root: String) -> Int {
    var files = 0
    var stack = [root]
    while let directory = stack.popLast() {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [] where !name.hasPrefix(".") {
            let path = directory + "/" + name
            let type = (try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType
            if type == .typeDirectory { stack.append(path) } else { files += 1 }
        }
    }
    return files
}

/// Key streams for the interner benchmarks (ADR 0019): maintastic's USR and token dumps when `AEMI_INTERNER_CORPUS` names
/// the directory holding `usrs.txt` and `tokens.txt` (one key per line, an empty line between files), else seeded
/// look-alikes of the same shape: 660,000 USR-like keys of about 120 bytes over 120,000 distinct, and 1.1 million token-like
/// keys over 30,000 distinct, a few of them hot. Each stream is split into runs of about 220 keys, as files are.
private struct KeyStream {
    /// Every key's bytes back to back, as a reader's buffer holds them.
    let storage: [UInt8]
    let starts: [Int]
    let lengths: [Int]
    let runs: [Range<Int>]

    var count: Int { starts.count }

    init(keys: [[UInt8]], runs: [Range<Int>]) {
        var storage: [UInt8] = []
        var starts: [Int] = []
        var lengths: [Int] = []
        for key in keys {
            starts.append(storage.count)
            lengths.append(key.count)
            storage += key
        }
        self.storage = storage
        self.starts = starts
        self.lengths = lengths
        self.runs = runs
    }

    /// Calls `body` with each key of `range`, in order, as a slice of one buffer.
    func forEach(in range: Range<Int>, _ body: (UnsafeRawBufferPointer) -> Void) {
        storage.withUnsafeBytes { buffer in
            for index in range {
                body(UnsafeRawBufferPointer(rebasing: buffer[starts[index] ..< (starts[index] + lengths[index])]))
            }
        }
    }

    static func load(_ name: String, synthetic: () -> [[UInt8]]) -> KeyStream {
        var keys: [[UInt8]] = []
        var runs: [Range<Int>] = []
        if let directory = ProcessInfo.processInfo.environment["AEMI_INTERNER_CORPUS"],
            let data = FileManager.default.contents(atPath: directory + "/" + name)
        {
            var start = 0
            for line in data.split(separator: 0x0A, omittingEmptySubsequences: false) {
                if line.isEmpty {
                    if keys.count > start { runs.append(start ..< keys.count) }
                    start = keys.count
                } else {
                    keys.append(Array(line))
                    if keys.count - start == 220 && name == "usrs.txt" {
                        runs.append(start ..< keys.count)
                        start = keys.count
                    }
                }
            }
            if keys.count > start { runs.append(start ..< keys.count) }
        } else {
            keys = synthetic()
            runs = stride(from: 0, to: keys.count, by: 220).map { $0 ..< Swift.min($0 + 220, keys.count) }
        }
        return KeyStream(keys: keys, runs: runs)
    }
}

private func syntheticKeys(count: Int, distinct: Int, length: Int, hot: Int) -> [[UInt8]] {
    var state: UInt64 = 0x0019
    func next() -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int(truncatingIfNeeded: state >> 33)
    }
    let vocabulary: [[UInt8]] = (0 ..< distinct)
        .map { index in
            let width = Swift.max(1, length / 2 + next() % Swift.max(1, length))
            var key = Array("k\(index)-".utf8)
            while key.count < width { key.append(UInt8(97 + next() % 26)) }
            return key
        }
    return (0 ..< count)
        .map { _ in hot > 0 && next() % 3 == 0 ? vocabulary[next() % hot] : vocabulary[next() % distinct] }
}

private let usrStream = KeyStream.load("usrs.txt") {
    syntheticKeys(count: 660_000, distinct: 120_000, length: 120, hot: 0)
}
private let tokenStream = KeyStream.load("tokens.txt") {
    syntheticKeys(count: 1_100_000, distinct: 30_000, length: 6, hot: 40)
}

/// Today's interning in the analyzers: a `String` per key into `[String: UInt32]`.
private func dictionaryIntern(_ stream: KeyStream) -> Int {
    var table: [String: UInt32] = [:]
    var sum: UInt32 = 0
    stream.forEach(in: 0 ..< stream.count) { key in
        let text = String(decoding: key, as: UTF8.self)
        if let symbol = table[text] {
            sum &+= symbol
        } else {
            table[text] = UInt32(table.count)
        }
    }
    return Int(sum) &+ table.count
}

private func arenaIntern(_ stream: KeyStream) -> Int {
    let interner = Interner()
    var sum: UInt32 = 0
    stream.forEach(in: 0 ..< stream.count) { sum &+= interner.intern($0).rawValue }
    return Int(sum) &+ interner.count
}

private func mergedIntern(_ stream: KeyStream, workers: Int) -> Int {
    let locals: [Interner] = (0 ..< workers).map { _ in Interner() }
    let parts: [Range<Int>] = (0 ..< workers)
        .map { part in
            let lower = stream.runs[stream.runs.count * part / workers].lowerBound
            let upper =
                part == workers - 1 ? stream.count : stream.runs[stream.runs.count * (part + 1) / workers].lowerBound
            return lower ..< upper
        }
    DispatchQueue.concurrentPerform(iterations: workers) { part in
        let local = locals[part]
        stream.forEach(in: parts[part]) { _ = local.intern($0) }
    }
    let merged = Interner.merge(locals, workers: workers)
    return merged.interner.count
}

nonisolated(unsafe) let benchmarks = {
    Benchmark.defaultConfiguration = .init(metrics: [.wallClock, .throughput])

    // MARK: edit distance — full vs banded vs adaptive at representative (length, bound) points.
    for (n, k) in [(32, 2), (64, 2), (128, 2), (256, 3)] {
        let (a, b) = nearStrings(n, edits: k)
        Benchmark("editDistance/full n\(n) k\(k)") { bm in
            for _ in bm.scaledIterations { blackHole(AemiText.editDistanceFull(a, b, maxDistance: k)) }
        }
        Benchmark("editDistance/banded n\(n) k\(k)") { bm in
            for _ in bm.scaledIterations { blackHole(AemiText.editDistanceBanded(a, b, maxDistance: k)) }
        }
        Benchmark("editDistance/adaptive n\(n) k\(k)") { bm in
            for _ in bm.scaledIterations { blackHole(AemiText.editDistance(a, b, maxDistance: k)) }
        }
    }

    // MARK: ByteBufferPool take/recycle throughput — the baseline for the zero-dependency, LIFO
    // Array backing. A swift-collections `Deque` is deliberately not adopted: the pool only appends
    // and pops the tail (both O(1) on Array), so a deque's O(1) head removal buys nothing here, and
    // AemiKernel must stay dependency-free for the portable consumers. This guards the backing against
    // regressions.
    for size in [64, 4096] {
        let pool = ByteBufferPool()
        let payload = [UInt8](repeating: 0xAB, count: size)
        Benchmark("pool/take-recycle \(size)B") { bm in
            for _ in bm.scaledIterations {
                var b = pool.take()
                b.append(contentsOf: payload)
                blackHole(b.count)
                pool.recycle(b)
            }
        }
    }

    // MARK: UTF-8 validation — scalar vs adaptive(SIMD), ASCII vs multibyte-dense.
    for n in [256, 4096] {
        let ascii = asciiBytes(n)
        let mixed = mixedBytes(n)
        Benchmark("utf8/scalar ascii \(n)") { bm in
            for _ in bm.scaledIterations { blackHole(UTF8Validation.firstInvalidByteScalar(ascii) ?? -1) }
        }
        Benchmark("utf8/adaptive ascii \(n)") { bm in
            for _ in bm.scaledIterations { blackHole(UTF8Validation.firstInvalidByte(ascii) ?? -1) }
        }
        Benchmark("utf8/scalar mixed \(n)") { bm in
            for _ in bm.scaledIterations { blackHole(UTF8Validation.firstInvalidByteScalar(mixed) ?? -1) }
        }
        Benchmark("utf8/adaptive mixed \(n)") { bm in
            for _ in bm.scaledIterations { blackHole(UTF8Validation.firstInvalidByte(mixed) ?? -1) }
        }
    }

    // MARK: SIMD kernels — the scalar C reference (the differential-test oracle) vs the runtime-
    // dispatched backend (NEON/dotprod on arm64, SSE2/SSE4.2/AVX2 on x86-64, selected once at runtime).
    // `foldASCII` over mixed-case content; `string-stop` over long plain content (the JSON tape-scan
    // hot loop). The scalar-vs-fastest crossover is what justifies the kernel shipping at each size.
    let stopQuote = UInt8(ascii: "\"")
    let stopEscape = UInt8(ascii: "\\")
    for n in [64, 256, 4096] {
        let content = contentBytes(n)
        Benchmark("kernels/fold scalar \(n)") { bm in
            for _ in bm.scaledIterations { blackHole(AemiKernels.foldedASCII(content, backend: .scalar)) }
        }
        Benchmark("kernels/fold fastest \(n)") { bm in
            for _ in bm.scaledIterations { blackHole(AemiKernels.foldedASCII(content, backend: .fastest)) }
        }
        Benchmark("kernels/string-stop scalar \(n)") { bm in
            for _ in bm.scaledIterations {
                blackHole(
                    AemiKernels.indexOfStringStop(content, quote: stopQuote, escape: stopEscape, backend: .scalar) ?? -1
                )
            }
        }
        Benchmark("kernels/string-stop fastest \(n)") { bm in
            for _ in bm.scaledIterations {
                blackHole(
                    AemiKernels.indexOfStringStop(content, quote: stopQuote, escape: stopEscape, backend: .fastest)
                        ?? -1)
            }
        }
    }

    // MARK: hamming distance — the semantic-search KNN scan (a query vs a corpus of 64-byte / 512-bit
    // sign-quantized embedding vectors). Scalar (POPCNT-lowered) vs the runtime-dispatched kernel
    // (NEON `cnt`). This is the `ShortlistByHamming` / `MMR` per-query hot loop.
    let hammingQuery = (0 ..< 64).map { UInt8(($0 &* 37) & 0xFF) }
    let hammingCorpus = (0 ..< 1000).map { row in (0 ..< 64).map { UInt8((row &* 31 &+ $0 &* 53) & 0xFF) } }
    Benchmark("kernels/hamming-scan scalar 1000x64") { bm in
        for _ in bm.scaledIterations {
            var sum = 0
            hammingQuery.withUnsafeBufferPointer { pq in
                guard let bq = pq.baseAddress else { return }
                for vector in hammingCorpus {
                    vector.withUnsafeBufferPointer { pv in
                        guard let bv = pv.baseAddress else { return }
                        sum += AemiKernels.hammingDistance(bq, bv, count: 64, backend: .scalar)
                    }
                }
            }
            blackHole(sum)
        }
    }
    Benchmark("kernels/hamming-scan fastest 1000x64") { bm in
        for _ in bm.scaledIterations {
            var sum = 0
            hammingQuery.withUnsafeBufferPointer { pq in
                guard let bq = pq.baseAddress else { return }
                for vector in hammingCorpus {
                    vector.withUnsafeBufferPointer { pv in
                        guard let bv = pv.baseAddress else { return }
                        sum += AemiKernels.hammingDistance(bq, bv, count: 64, backend: .fastest)
                    }
                }
            }
            blackHole(sum)
        }
    }
    // Batched scan: one dispatch over a contiguous corpus (the primitive KNN shortlisting should use).
    let hammingFlat = (0 ..< 1000 * 64).map { UInt8(($0 &* 53 &+ 7) & 0xFF) }
    Benchmark("kernels/hamming-scan batched 1000x64") { bm in
        var out = [UInt32](repeating: 0, count: 1000)
        for _ in bm.scaledIterations {
            hammingQuery.withUnsafeBufferPointer { pq in
                hammingFlat.withUnsafeBufferPointer { pc in
                    out.withUnsafeMutableBufferPointer { po in
                        guard let bq = pq.baseAddress, let bc = pc.baseAddress, let bo = po.baseAddress
                        else { return }
                        AemiKernels.hammingScan(query: bq, corpus: bc, width: 64, count: 1000, into: bo)
                    }
                }
            }
            blackHole(out[0])
        }
    }

    // MARK: copy-on-write / allocation guards. These track `.mallocCountTotal` (collected in CI,
    // where jemalloc is installed) so a reintroduced copy-on-write copy or per-append reallocation in
    // the byte-building primitives fails the threshold instead of silently rotting. They cover the
    // OutputSpan / single-allocation adoption in `PercentCoding` and `Varint`.
    let cowMetrics = Benchmark.Configuration(metrics: [.wallClock, .throughput, .mallocCountTotal])

    let escapeHeavy = PercentCoding.encode(mixedBytes(256))  // mostly %XX triples
    Benchmark("cow/percent-decode escape-heavy 256", configuration: cowMetrics) { bm in
        for _ in bm.scaledIterations { blackHole(PercentCoding.decode(escapeHeavy)) }
    }
    // percent-ENCODE — the direction the decode case above did not cover. An ASCII-safe run (few
    // escapes, the common case) next to an escape-heavy run (mostly `%XX` triples), so the encoder's
    // single-allocation OutputSpan build is guarded in both regimes.
    let percentSafe = asciiBytes(256)
    let percentRaw = mixedBytes(256)
    Benchmark("cow/percent-encode ascii-safe 256", configuration: cowMetrics) { bm in
        for _ in bm.scaledIterations { blackHole(PercentCoding.encode(percentSafe)) }
    }
    Benchmark("cow/percent-encode escape-heavy 256", configuration: cowMetrics) { bm in
        for _ in bm.scaledIterations { blackHole(PercentCoding.encode(percentRaw)) }
    }

    // Build a run of varints two ways: the reserve+append array form vs. the exclusively-owned
    // OutputSpan form. Both should allocate exactly once; the benchmark guards that invariant.
    let varintValues: [UInt64] = (0 ..< 256).map { UInt64($0) &* 2_654_435_761 }
    let varintCapacity = varintValues.count * Varint.maxEncodedLength
    Benchmark("cow/varint-build array", configuration: cowMetrics) { bm in
        for _ in bm.scaledIterations {
            var out: [UInt8] = []
            out.reserveCapacity(varintCapacity)
            for v in varintValues { Varint.append(v, to: &out) }
            blackHole(out.count)
        }
    }
    Benchmark("cow/varint-build outputspan", configuration: cowMetrics) { bm in
        for _ in bm.scaledIterations {
            let out = [UInt8](capacity: varintCapacity) { span in
                for v in varintValues { Varint.append(v, to: &span) }
            }
            blackHole(out.count)
        }
    }

    // MARK: endian append — the single bounded-copy `appendLE64` vs the per-shift `append` loop the
    // framers hand-rolled (eight `append`s per UInt64). cowMetrics so the allocation profile stays
    // flat (one amortized growth, reserved up front in both arms) while the wall-clock win shows.
    let endianValues: [UInt64] = (0 ..< 256).map { UInt64($0) &* 0x9E37_79B9_7F4A_7C15 }
    let endianCapacity = endianValues.count * 8
    Benchmark("endian/appendLE64 new", configuration: cowMetrics) { bm in
        for _ in bm.scaledIterations {
            var out: [UInt8] = []
            out.reserveCapacity(endianCapacity)
            for v in endianValues { out.appendLE64(v) }
            blackHole(out.count)
        }
    }
    Benchmark("endian/appendLE64 naive(old)", configuration: cowMetrics) { bm in
        for _ in bm.scaledIterations {
            var out: [UInt8] = []
            out.reserveCapacity(endianCapacity)
            for v in endianValues { naiveAppendLE64(v, to: &out) }
            blackHole(out.count)
        }
    }

    // MARK: XML escaping — the byte-level `XMLEscape` (one result allocation) vs the per-`Character`
    // `String +=` escaper the SVG/XML builders hand-rolled. cowMetrics guards the allocation profile
    // (the safe-run arm is one alloc) alongside the wall-clock win on mixed input.
    let xmlSafe = String(repeating: "UIView.layoutMarginsGuide ", count: 8)
    let xmlMixed = String(repeating: "a<b> & \"c\" 'd' ", count: 8)
    Benchmark("xml/escape safe", configuration: cowMetrics) { bm in
        for _ in bm.scaledIterations { blackHole(XMLEscape.escaped(xmlSafe)) }
    }
    Benchmark("xml/escape mixed new", configuration: cowMetrics) { bm in
        for _ in bm.scaledIterations { blackHole(XMLEscape.escaped(xmlMixed)) }
    }
    Benchmark("xml/escape mixed naive(old)", configuration: cowMetrics) { bm in
        for _ in bm.scaledIterations { blackHole(naiveXMLEscape(xmlMixed)) }
    }

    // MARK: number parsing — the allocation-free Clinger fast path (the `DecimalFloat` kernel shared
    // with ADJSON's tape parser) vs the allocating shape it replaced, side by side. `.mallocCountTotal`
    // makes the win concrete: the new path allocates nothing on the fast path, the old made roughly one
    // heap allocation per intermediate array/string per call.
    let numberInputs = ["0.65", "123.456", "42", "-2.5", "1000000", "0.7"].map { Array($0.utf8) }
    Benchmark("number/doublePrefix new", configuration: cowMetrics) { bm in
        for _ in bm.scaledIterations { for s in numberInputs { blackHole(NumberParse.doublePrefix(s)) } }
    }
    Benchmark("number/doublePrefix naive(old)", configuration: cowMetrics) { bm in
        for _ in bm.scaledIterations { for s in numberInputs { blackHole(naiveDoublePrefix(s)) } }
    }
    let intInputs = ["42", "-7", "1000000", "16", "255"].map { Array($0.utf8) }
    Benchmark("number/intPrefix", configuration: cowMetrics) { bm in
        for _ in bm.scaledIterations { for s in intInputs { blackHole(NumberParse.intPrefix(s)) } }
    }

    // MARK: base64 — encode/decode of a 32-byte SHA-256 digest (the SRI `sha256-…` token path). The
    // cowMetrics config guards the single-allocation OutputSpan build against a regression.
    let digest = [UInt8](repeating: 0xAB, count: 32)
    let digestBase64 = Base64.encode(digest)
    Benchmark("base64/encode 32B", configuration: cowMetrics) { bm in
        for _ in bm.scaledIterations { blackHole(Base64.encode(digest)) }
    }
    Benchmark("base64/decode 32B", configuration: cowMetrics) { bm in
        for _ in bm.scaledIterations { blackHole(Base64.decode(digestBase64)) }
    }

    // MARK: base64 options — a 4 KiB payload through the configurable paths. decode/encode `into:` are
    // the zero-allocation forms (`.mallocCountTotal` must stay 0); the others allocate only the result.
    // The `lenient` arm is the nil-returning legacy API on the same shared decode engine.
    let base64Payload = (0 ..< 4096).map { UInt8(truncatingIfNeeded: $0 &* 131 &+ ($0 >> 5)) }
    let base64Strict = Base64.encode(base64Payload, options: .strict)
    let base64Pem = Base64.encode(base64Payload, options: .pem)
    let base64UrlNoPadding = Base64.encode(base64Payload, options: .urlSafeNoPadding)
    Benchmark("base64/encode strict 4KiB", configuration: cowMetrics) { bm in
        for _ in bm.scaledIterations { blackHole(Base64.encode(base64Payload, options: .strict)) }
    }
    Benchmark("base64/encode pem 4KiB", configuration: cowMetrics) { bm in
        for _ in bm.scaledIterations { blackHole(Base64.encode(base64Payload, options: .pem)) }
    }
    Benchmark("base64/decode strict 4KiB", configuration: cowMetrics) { bm in
        for _ in bm.scaledIterations { blackHole(try? Base64.decode(base64Strict, options: .strict)) }
    }
    Benchmark("base64/decode lenient 4KiB", configuration: cowMetrics) { bm in
        for _ in bm.scaledIterations { blackHole(Base64.decode(base64Strict)) }
    }
    Benchmark("base64/decode pem 4KiB", configuration: cowMetrics) { bm in
        for _ in bm.scaledIterations { blackHole(try? Base64.decode(base64Pem, options: .pem)) }
    }
    Benchmark("base64/decode urlSafeNoPadding 4KiB", configuration: cowMetrics) { bm in
        for _ in bm.scaledIterations {
            blackHole(try? Base64.decode(base64UrlNoPadding, options: .urlSafeNoPadding))
        }
    }
    var base64Scratch = [UInt8](repeating: 0, count: 8192)
    Benchmark("base64/decode(into:) strict 4KiB", configuration: cowMetrics) { bm in
        for _ in bm.scaledIterations {
            base64Scratch.withUnsafeMutableBufferPointer { buffer in
                var span = MutableSpan(_unsafeElements: buffer)
                blackHole(try? Base64.decode(base64Strict, into: &span, options: .strict))
            }
        }
    }
    Benchmark("base64/encode(into:) strict 4KiB", configuration: cowMetrics) { bm in
        for _ in bm.scaledIterations {
            base64Scratch.withUnsafeMutableBufferPointer { buffer in
                var span = MutableSpan(_unsafeElements: buffer)
                blackHole(try? Base64.encode(base64Payload, into: &span, options: .strict))
            }
        }
    }

    // MARK: directory walk — a stat per entry (today's SourceDiscovery) against AemiFileSystem's readdir walker, 1 and 4
    // workers. The enforced threshold is an operation count (no stat per regular file, AemiFileSystemTests); these are
    // for comparing variants side by side, as wall time alone never gates.
    let root = walkTree
    Benchmark("directoryWalk/FileManager+attributes") { bm in
        for _ in bm.scaledIterations { blackHole(foundationWalk(root)) }
    }
    for workers in [1, 4] {
        Benchmark("directoryWalk/readdir \(workers) worker(s)") { bm in
            for _ in bm.scaledIterations {
                blackHole(try? DirectoryWalk.walk(root, policy: .init(workers: workers)).entries.count)
            }
        }
    }

    // MARK: interner — a String per key into [String: UInt32] against AemiInterner, one thread and merged over workers
    // (ADR 0019). The enforced gates are the interner's tests (no allocation per repeated key, deterministic symbols).
    for (name, stream) in [("usr", usrStream), ("token", tokenStream)] {
        Benchmark("interner/\(name) [String: UInt32]") { bm in
            for _ in bm.scaledIterations { blackHole(dictionaryIntern(stream)) }
        }
        Benchmark("interner/\(name) AemiInterner") { bm in
            for _ in bm.scaledIterations { blackHole(arenaIntern(stream)) }
        }
        Benchmark("interner/\(name) AemiInterner merged, 4 workers") { bm in
            for _ in bm.scaledIterations { blackHole(mergedIntern(stream, workers: 4)) }
        }
    }
}

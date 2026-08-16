import AemiKernel
import AemiKernels
import AemiText
import Benchmark

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
                blackHole(AemiKernels.indexOfStringStop(content, quote: stopQuote, escape: stopEscape, backend: .scalar) ?? -1)
            }
        }
        Benchmark("kernels/string-stop fastest \(n)") { bm in
            for _ in bm.scaledIterations {
                blackHole(AemiKernels.indexOfStringStop(content, quote: stopQuote, escape: stopEscape, backend: .fastest) ?? -1)
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
}

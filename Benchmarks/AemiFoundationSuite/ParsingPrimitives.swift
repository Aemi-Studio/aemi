import AemiInterner
import AemiKernel
import AemiKernels
import AemiText
import Benchmark

// The parsing primitives of ADR 0031, each beside what a parser used before it: the standard library's `Hasher` for short keys,
// a direct kernel call for short runs, a byte loop for indentation, a search per line for line starts, `Double(String)` for
// numbers. `AEMI_DEV=1 swift package benchmark --filter 'parse/.*'`.

/// Keys of the shapes configuration files use: 4 to 24 bytes.
private let shortKeys: [[UInt8]] = (0 ..< 4096)
    .map { index in
        Array(["name", "version", "dependencies", "checksum", "source", "features", "x", "edition"][index % 8].utf8)
            + Array(String(index).utf8)
    }

/// A line of configuration repeated: indentation, a key, a short quoted string, a comment.
private let configLines: [UInt8] = Array(
    String(repeating: "        name = \"crate-12\" # a short comment\n    version = \"1.2.3\"\n", count: 4000).utf8
)

/// Numbers as a GeoJSON file writes them.
private let coordinates: [UInt8] = Array(
    (0 ..< 20000).map { index in "-\(65 + index % 30).\(613_616_999_999_98 + index * 7919), " }.joined().utf8
)

func registerParsingPrimitives() {
    Benchmark("parse/hash short keys Hasher") { bm in
        for _ in bm.scaledIterations {
            var total = 0
            for key in shortKeys {
                var hasher = Hasher()
                key.withUnsafeBytes { hasher.combine(bytes: $0) }
                total &+= hasher.finalize()
            }
            blackHole(total)
        }
    }
    Benchmark("parse/hash short keys KeyedHash") { bm in
        let key = KeyedHash.process
        for _ in bm.scaledIterations {
            var total: UInt64 = 0
            for bytes in shortKeys { total &+= key.hash(bytes) }
            blackHole(total)
        }
    }
    Benchmark("parse/hash short keys WyHash (unkeyed)") { bm in
        for _ in bm.scaledIterations {
            var total: UInt64 = 0
            for bytes in shortKeys { total &+= WyHash.hash(bytes) }
            blackHole(total)
        }
    }
    Benchmark("parse/intern short keys fast") { bm in
        for _ in bm.scaledIterations {
            let interner = Interner(capacity: shortKeys.count)
            for key in shortKeys { blackHole(key.withUnsafeBytes { interner.intern($0) }) }
        }
    }
    Benchmark("parse/intern short keys keyed") { bm in
        for _ in bm.scaledIterations {
            let interner = Interner(capacity: shortKeys.count, hashing: .keyedForProcess)
            for key in shortKeys { blackHole(key.withUnsafeBytes { interner.intern($0) }) }
        }
    }
    // Every quote, comment and line end of the lines, one search at a time, as a tokenizer asks.
    Benchmark("parse/stops kernel call per search") { bm in
        for _ in bm.scaledIterations {
            var at = 0
            var hits = 0
            while at < configLines.count {
                let found = configLines.withUnsafeBufferPointer { buffer in
                    at
                        + AemiKernels.firstIndexOfAny(
                            base: buffer.baseAddress! + at,
                            count: buffer.count - at,
                            0x22,
                            0x23,
                            0x0A,
                            0x0A,
                            0x0A
                        )
                }
                at = found + 1
                hits += 1
            }
            blackHole(hits)
        }
    }
    Benchmark("parse/stops ByteScan (SWAR front)") { bm in
        for _ in bm.scaledIterations {
            var at = 0
            var hits = 0
            while at < configLines.count {
                at = ByteScan.firstIndexOfAny(in: configLines, from: at, 0x22, 0x23, 0x0A, 0x0A, 0x0A) + 1
                hits += 1
            }
            blackHole(hits)
        }
    }
    Benchmark("parse/indentation byte loop") { bm in
        for _ in bm.scaledIterations {
            var total = 0
            var at = 0
            while at < configLines.count {
                var end = at
                while end < configLines.count, configLines[end] == 0x20 || configLines[end] == 0x09 { end += 1 }
                total &+= end - at
                at = ByteScan.firstIndex(of: 0x0A, in: configLines, from: end) + 1
            }
            blackHole(total)
        }
    }
    Benchmark("parse/indentation ByteScan (exact SWAR)") { bm in
        for _ in bm.scaledIterations {
            var total = 0
            var at = 0
            while at < configLines.count {
                let end = ByteScan.firstIndexNotEither(0x20, 0x09, in: configLines, from: at)
                total &+= end - at
                at = ByteScan.firstIndex(of: 0x0A, in: configLines, from: end) + 1
            }
            blackHole(total)
        }
    }
    Benchmark("parse/line starts search per line") { bm in
        for _ in bm.scaledIterations {
            var starts: [Int] = [0]
            var at = 0
            while true {
                let found = configLines.withUnsafeBufferPointer { buffer in
                    at
                        + AemiKernels.firstIndexOfByte(
                            base: buffer.baseAddress! + at,
                            count: buffer.count - at,
                            needle: 0x0A
                        )
                }
                guard found < configLines.count else { break }
                at = found + 1
                starts.append(at)
            }
            blackHole(starts.count)
        }
    }
    Benchmark("parse/line starts LineIndex (positions kernel)") { bm in
        for _ in bm.scaledIterations { blackHole(LineIndex(configLines, breaks: .lineFeed).lineCount) }
    }
    Benchmark("parse/numbers Double(String)") { bm in
        for _ in bm.scaledIterations {
            var total = 0.0
            var at = 0
            while let literal = DecimalScanner.scan(coordinates, from: at) {
                total += Double(String(decoding: coordinates[literal.start ..< literal.end], as: UTF8.self)) ?? 0
                at = literal.end + 2
            }
            blackHole(total)
        }
    }
    Benchmark("parse/numbers DecimalScanner + DecimalFloat") { bm in
        for _ in bm.scaledIterations {
            var total = 0.0
            var at = 0
            while let literal = DecimalScanner.scan(coordinates, from: at) {
                total += DecimalFloat.double(literal, in: coordinates)
                at = literal.end + 2
            }
            blackHole(total)
        }
    }
}

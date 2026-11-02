// AemiBase64Probe — standalone differential check of Base64 on the host's SIMD tier, for architectures the test target
// cannot be built for: `swift run --arch x86_64 AemiBase64Probe` under Rosetta 2 (SSSE3), and with ROSETTA_ADVERTISE_AVX=1
// (AVX2). Contiguous input takes the block kernels; a collection that hides its storage takes the byte engine, which never
// uses them, so the two must agree on every value and every typed error with its offset. Exits 1 on a mismatch.
import AemiKernel
import AemiKernels

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

struct HiddenBytes: Collection {
    let storage: [UInt8]
    var startIndex: Int { 0 }
    var endIndex: Int { storage.count }
    func index(after index: Int) -> Int { index + 1 }
    subscript(position: Int) -> UInt8 { storage[position] }
}

struct Probe {
    var state: UInt64 = 0x9E37_79B9_7F4A_7C15
    var checks = 0
    var failures = 0

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }

    mutating func bytes(_ count: Int) -> [UInt8] {
        (0 ..< count).map { _ in UInt8(truncatingIfNeeded: next()) }
    }

    mutating func expect(_ condition: Bool, _ message: @autoclosure () -> String) {
        checks += 1
        guard !condition else { return }
        failures += 1
        if failures <= 10 { print("FAIL", message()) }
    }

    static func outcome(_ body: () throws -> [UInt8]) -> String {
        do { return "ok \(try body())" } catch { return "error \(error)" }
    }

    static func naiveEncode(_ input: [UInt8], _ table: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var index = 0
        while index + 3 <= input.count {
            let v = UInt32(input[index]) << 16 | UInt32(input[index + 1]) << 8 | UInt32(input[index + 2])
            out += [table[Int(v >> 18)], table[Int(v >> 12 & 63)], table[Int(v >> 6 & 63)], table[Int(v & 63)]]
            index += 3
        }
        let rest = input.count - index
        if rest == 1 {
            let v = UInt32(input[index]) << 16
            out += [table[Int(v >> 18)], table[Int(v >> 12 & 63)], 61, 61]
        } else if rest == 2 {
            let v = UInt32(input[index]) << 16 | UInt32(input[index + 1]) << 8
            out += [table[Int(v >> 18)], table[Int(v >> 12 & 63)], table[Int(v >> 6 & 63)], 61]
        }
        return out
    }

    mutating func alphabets() throws -> [(String, Base64.AlphabetTable)] {
        var shuffled = Array(Base64.AlphabetTable.standard.symbols)
        for i in stride(from: 63, to: 0, by: -1) { shuffled.swapAt(i, Int(next() % UInt64(i + 1))) }
        var ranged = Array(Base64.AlphabetTable.standard.symbols)
        ranged[62] = UInt8(ascii: "*")
        ranged[63] = UInt8(ascii: ",")
        return [
            ("standard", .standard), ("urlSafe", .urlSafe),
            ("shuffled", try Base64.AlphabetTable(symbols: shuffled)),
            ("A-Za-z0-9 + * ,", try Base64.AlphabetTable(symbols: ranged))
        ]
    }

    mutating func run() throws {
        let breakers: [UInt8] = [42, 45, 32, 0x80, 0xFF, 0, 61, 10]
        for (name, table) in try alphabets() {
            var strict = Base64.Options.strict
            strict.alphabet = table
            var mime = Base64.Options.mime
            mime.alphabet = table
            var lenient = Base64.Options.lenient
            lenient.alphabet = table
            for count in 0 ... 400 {
                let input = bytes(count)
                let encoded = Base64.encode(input, options: strict)
                expect(encoded == Self.naiveEncode(input, table.symbols), "\(name) encode \(count)")
                expect((try? Base64.decode(encoded, options: strict)) == input, "\(name) round trip \(count)")
                let wrapped = Base64.encode(input, options: mime)
                expect((try? Base64.decode(wrapped, options: mime)) == input, "\(name) mime round trip \(count)")
                if count % 5 == 0 {
                    for position in 0 ..< encoded.count {
                        var broken = encoded
                        broken[position] = breakers[(position + count) % breakers.count]
                        for options in [strict, lenient] {
                            let fast = Self.outcome { try Base64.decode(broken, options: options) }
                            let slow = Self.outcome {
                                try Base64.decode(HiddenBytes(storage: broken), options: options)
                            }
                            expect(fast == slow, "\(name) n=\(count) at \(position): \(fast) vs \(slow)")
                        }
                    }
                }
                for limit in [0, 1, 7, count / 2, count - 1, count, count + 1] where limit >= 0 {
                    var limited = strict
                    limited.maximumDecodedSize = limit
                    let fast = Self.outcome { try Base64.decode(encoded, options: limited) }
                    let slow = Self.outcome { try Base64.decode(HiddenBytes(storage: encoded), options: limited) }
                    expect(fast == slow, "\(name) limit \(limit) n=\(count)")
                }
            }
        }
        for count in [150_001, 1 << 20] {
            let input = bytes(count)
            for options in [Base64.Options.strict, .urlSafeNoPadding, .pem, .mime] {
                expect(
                    (try? Base64.decode(Base64.encode(input, options: options), options: options)) == input,
                    "large \(count)"
                )
            }
        }
    }
}

var probe = Probe()
do { try probe.run() } catch {
    print("probe error:", error)
    exit(2)
}
print("backend \(AemiKernels.activeBackend): \(probe.checks) checks, \(probe.failures) failures")
exit(probe.failures == 0 ? 0 : 1)

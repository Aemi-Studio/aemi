import AemiInterner
import AemiTestKit
import Dispatch
import Testing

/// Keys of every shape the analyzers meet: empty, one byte, short tokens, multi-byte UTF-8, USR-length, and over 48
/// bytes (wyhash's long loop).
private let shapes: [String] = [
    "", "a", "let", "func", "é", "日本語", "s:7Example4UserV", "c:objc(cs)NSObject",
    "s:14OculavisShareIOS21StockHandlingViewModelC12updateAmount_2bySS_SitF",
    String(repeating: "x", count: 48), String(repeating: "y", count: 97)
]

/// A seeded corpus: `inputs` runs of picks from a vocabulary of `vocabulary` keys, skewed so a few keys are hot (as tokens
/// are) and the rest rare (as USRs are), with keys shared between runs.
private func corpus(inputs: Int, picks: Int, vocabulary: Int, seed: UInt64) -> [[String]] {
    var random = SeededRNG(seed: seed)
    var words: [String] = shapes
    while words.count < vocabulary {
        let length: Int = 1 + random.uniform(160)
        let scalars: [Character] = (0 ..< length)
            .map { _ in
                let pick: Int = random.uniform(40)
                return pick == 0 ? "é" : Character(Unicode.Scalar(UInt8(97 + pick % 26)))
            }
        words.append(String(scalars))
    }
    var result: [[String]] = []
    for _ in 0 ..< inputs {
        var run: [String] = []
        for _ in 0 ..< picks {
            let hot: Bool = random.uniform(3) == 0
            let index: Int = hot ? random.uniform(20) : random.uniform(words.count)
            run.append(words[index])
        }
        result.append(run)
    }
    return result
}

private func bytes(_ interner: Interner, _ symbol: Symbol) -> [UInt8] {
    interner.withBytes(of: symbol) { [UInt8]($0) }
}

private func bytes(_ interner: FrozenInterner, _ symbol: Symbol) -> [UInt8] {
    interner.withBytes(of: symbol) { [UInt8]($0) }
}

@Suite struct InternerTests {
    @Test func `symbols are dense, in first-occurrence order, and resolve to their keys`() {
        let interner = Interner()
        let first: [Symbol] = shapes.map { interner.intern($0) }
        let again: [Symbol] = shapes.reversed().map { interner.intern($0) }
        let expected: [Symbol] = (0 ..< shapes.count).map { Symbol(rawValue: UInt32($0)) }
        #expect(first == expected)
        #expect(again == expected.reversed())
        #expect(interner.count == shapes.count)
        for (index, key) in shapes.enumerated() {
            let symbol = Symbol(rawValue: UInt32(index))
            #expect(interner.string(of: symbol) == key)
            #expect(bytes(interner, symbol) == Array(key.utf8))
        }
    }

    @Test func `bytes, a String and a Substring of the same key are one symbol`() {
        let interner = Interner()
        let line = "prefix s:7Example4UserV suffix"
        let substring: Substring = line.split(separator: " ")[1]
        let fromString: Symbol = interner.intern("s:7Example4UserV")
        let fromSubstring: Symbol = interner.intern(substring)
        let fromBytes: Symbol = Array("s:7Example4UserV".utf8).withUnsafeBytes { interner.intern($0) }
        #expect(fromString == fromSubstring && fromString == fromBytes)
        #expect(interner.count == 1)
    }

    @Test func `a lookup finds what was interned and nothing else, without interning`() {
        let interner = Interner()
        for key in shapes { _ = interner.intern(key) }
        for (index, key) in shapes.enumerated() {
            #expect(interner.symbol(for: key) == Symbol(rawValue: UInt32(index)))
        }
        #expect(interner.symbol(for: "absent") == nil)
        let absentBytes: Symbol? = Array("lets".utf8).withUnsafeBytes { interner.symbol(for: $0) }
        #expect(absentBytes == nil)
        #expect(interner.count == shapes.count)
    }

    @Test func `the table grows past many keys and a key larger than a chunk, and every key still resolves`() {
        let interner = Interner()
        let count = 150_000
        for index in 0 ..< count { _ = interner.intern("key-\(index)") }
        let huge = String(repeating: "z", count: 200_000)
        let hugeSymbol: Symbol = interner.intern(huge)
        #expect(interner.count == count + 1)
        #expect(hugeSymbol == Symbol(rawValue: UInt32(count)))
        #expect(interner.string(of: hugeSymbol) == huge)
        var wrong = 0
        for index in stride(from: 0, to: count, by: 7)
        where interner.string(of: Symbol(rawValue: UInt32(index))) != "key-\(index)" {
            wrong += 1
        }
        #expect(wrong == 0)
        #expect(interner.symbol(for: "key-149999") == Symbol(rawValue: 149_999))
    }

    /// The merge's whole promise: the sequential symbols, for any number of workers, inputs and shapes of input.
    @Test(arguments: [1, 2, 3, 4, 8])
    func `a merge gives the symbols one interner reading every input in order gives`(workers: Int) throws {
        let inputs: [[String]] = corpus(inputs: 9, picks: 4_000, vocabulary: 6_000, seed: 0x0019) + [[]]
        let sequential = Interner()
        let expected: [[Symbol]] = inputs.map { run in run.map { sequential.intern($0) } }
        var locals: [Interner] = []
        var localSymbols: [[Symbol]] = []
        for run in inputs {
            let local = Interner()
            localSymbols.append(run.map { local.intern($0) })
            locals.append(local)
        }
        let merged = Interner.merge(locals, workers: workers)
        #expect(merged.interner.count == sequential.count)
        try #require(merged.remaps.count == inputs.count)
        for (input, local) in locals.enumerated() { try #require(merged.remaps[input].count == local.count) }
        var mismatches = 0
        for (input, symbols) in localSymbols.enumerated() {
            let remapped: [Symbol] = symbols.map { merged.remaps[input][Int($0.rawValue)] }
            if remapped != expected[input] { mismatches += 1 }
        }
        #expect(mismatches == 0)
        var wrongBytes = 0
        for raw in 0 ..< UInt32(sequential.count)
        where bytes(merged.interner, Symbol(rawValue: raw)) != bytes(sequential, Symbol(rawValue: raw)) {
            wrongBytes += 1
        }
        #expect(wrongBytes == 0)
        #expect(merged.interner.serialized() == sequential.serialized())
    }

    @Test func `a frozen interner answers lookups from many threads at once`() {
        let interner = Interner()
        let keys: [String] = corpus(inputs: 1, picks: 3_000, vocabulary: 3_000, seed: 7)[0]
        let symbols: [Symbol] = keys.map { interner.intern($0) }
        let frozen: FrozenInterner = interner.freeze()
        let failures = Counter()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            for (key, symbol) in zip(keys, symbols)
            where frozen.symbol(for: key) != symbol || frozen.string(of: symbol) != key {
                failures.increment()
            }
        }
        #expect(failures.value == 0)
        #expect(frozen.count == interner.count)
    }

    @Test func `serialized keys read back under the same symbols`() throws {
        let interner = Interner()
        for key in shapes + (0 ..< 2_000).map({ "key-\($0)" }) { _ = interner.intern(key) }
        let serialized: [UInt8] = interner.serialized()
        let read = try Interner(serialized: serialized)
        #expect(interner.count == shapes.count + 2_000)
        #expect(read.count == interner.count)
        var wrong = 0
        for raw in 0 ..< UInt32(interner.count)
        where bytes(read, Symbol(rawValue: raw)) != bytes(interner, Symbol(rawValue: raw)) {
            wrong += 1
        }
        #expect(wrong == 0)
        #expect(read.serialized() == serialized)
        #expect(interner.freeze().serialized() == serialized)
        let empty = try Interner(serialized: Interner().serialized())
        #expect(empty.count == 0)
    }

    @Test func `damaged serialized bytes are refused, saying how`() {
        let interner = Interner()
        for key in ["a", "bc", "def"] { _ = interner.intern(key) }
        let good: [UInt8] = interner.serialized()
        #expect(good == [3, 1, 2, 3] + Array("abcdef".utf8))
        #expect(throws: InternerFormatError.truncated) { try Interner(serialized: Array(good.dropLast())) }
        #expect(throws: InternerFormatError.truncated) { try Interner(serialized: []) }
        #expect(throws: InternerFormatError.truncated) { try Interner(serialized: [2, 0x80]) }
        #expect(throws: InternerFormatError.trailingBytes) { try Interner(serialized: good + [0]) }
        let duplicated: [UInt8] = [2, 1, 1] + Array("aa".utf8)
        #expect(throws: InternerFormatError.duplicateKey(Symbol(rawValue: 1))) { try Interner(serialized: duplicated) }
    }
}

/// A count several threads add to.
private final class Counter: @unchecked Sendable {
    private let lock = DispatchQueue(label: "counter")
    private var count = 0

    var value: Int { lock.sync { count } }

    func increment() { lock.sync { count += 1 } }
}

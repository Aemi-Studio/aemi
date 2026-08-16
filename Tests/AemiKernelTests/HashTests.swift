import AemiKernel
import Testing

struct XXH64Tests {
    @Test func emptyInputKnownVector() {
        // Canonical xxHash64 of the empty input with seed 0.
        #expect(XXH64.hash([]) == 0xEF46_DB37_51D8_E999)
    }

    @Test func deterministicAndSeedSensitive() {
        let data = Array("The quick brown fox jumps over the lazy dog".utf8)
        #expect(XXH64.hash(data) == XXH64.hash(data))
        #expect(XXH64.hash(data, seed: 1) != XXH64.hash(data, seed: 2))
    }

    @Test func lengthSensitive() {
        #expect(XXH64.hash(Array("abc".utf8)) != XXH64.hash(Array("abcd".utf8)))
    }

    @Test func rawBufferAndArrayAgreeAcrossLanes() {
        // Exercises the >=32B main loop, the 8B and 4B tails, and the single-byte tail.
        for count in [0, 1, 4, 7, 8, 15, 31, 32, 33, 200] {
            let data = (0 ..< count).map { UInt8($0 & 0xFF) }
            let viaArray = XXH64.hash(data, seed: 0x1234)
            let viaRaw = data.withUnsafeBytes { XXH64.hash($0, seed: 0x1234) }
            #expect(viaArray == viaRaw)
        }
    }
}

struct ByteCompareTests {
    private func equal(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        return a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                guard let ba = pa.baseAddress, let bb = pb.baseAddress else { return a.isEmpty }
                return ByteCompare.equal(ba, bb, a.count)
            }
        }
    }

    @Test func equalBuffers() {
        let x = Array("hello, world — a key longer than eight bytes".utf8)
        #expect(equal(x, x))
        #expect(equal([], []))
        #expect(equal([1, 2, 3], [1, 2, 3]))
    }

    @Test func unequalBuffers() {
        var x = Array("hello, world — a key longer than eight bytes".utf8)
        var y = x
        y[20] ^= 0xFF  // differ in the word-at-a-time region
        #expect(!equal(x, y))
        x = [1, 2, 3]
        #expect(!equal(x, [1, 2, 4]))  // differ in the scalar remainder
    }
}

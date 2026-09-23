import AemiKernels
import AemiTestKit
import Testing

// Hamming-distance kernel: exact-integer, so `.fastest` (NEON/POPCNT) must equal `.scalar` AND an
// independent per-byte-popcount reference, across widths incl. the SIMD/tail boundaries and the fixed
// 64-byte embedding width the semantic-search KNN scan uses.
struct AemiKernelsHammingTests {
    static func referenceDistance(_ a: [UInt8], _ b: [UInt8]) -> Int {
        var total = 0
        for i in 0 ..< Swift.min(a.count, b.count) { total += (a[i] ^ b[i]).nonzeroBitCount }
        return total
    }

    static func distance(_ a: [UInt8], _ b: [UInt8], _ backend: AemiKernels.Backend) -> Int {
        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                guard let baseA = pa.baseAddress, let baseB = pb.baseAddress else { return 0 }
                return AemiKernels.hammingDistance(baseA, baseB, count: a.count, backend: backend)
            }
        }
    }

    @Test func knownCases() {
        let width = 64
        let zeros = [UInt8](repeating: 0x00, count: width)
        let ones = [UInt8](repeating: 0xFF, count: width)
        #expect(Self.distance(zeros, zeros, .fastest) == 0)
        #expect(Self.distance(ones, ones, .fastest) == 0)
        #expect(Self.distance(zeros, ones, .fastest) == width * 8)  // every bit differs
        #expect(Self.distance([0b1010_1010], [0b0101_0101], .fastest) == 8)
    }

    @Test func batchedScanMatchesPerVectorReference() {
        var rng = SeededRNG(seed: 0xBEEF_1234_5678_9ABC)
        var mismatches = 0
        for _ in 0 ..< 500 {
            let width = [1, 16, 32, 64, 100][rng.int(5)]
            let count = 1 + rng.int(40)
            var query: [UInt8] = []
            for _ in 0 ..< width { query.append(UInt8(rng.int(256))) }
            var corpus: [UInt8] = []
            for _ in 0 ..< width * count { corpus.append(UInt8(rng.int(256))) }
            var out = [UInt32](repeating: 0, count: count)
            query.withUnsafeBufferPointer { pq in
                corpus.withUnsafeBufferPointer { pc in
                    out.withUnsafeMutableBufferPointer { po in
                        guard let bq = pq.baseAddress, let bc = pc.baseAddress, let bo = po.baseAddress
                        else { return }
                        AemiKernels.hammingScan(query: bq, corpus: bc, width: width, count: count, into: bo)
                    }
                }
            }
            for v in 0 ..< count {
                let vector = Array(corpus[(v * width) ..< ((v + 1) * width)])
                if Int(out[v]) != Self.referenceDistance(query, vector) { mismatches += 1 }
            }
        }
        #expect(mismatches == 0)
    }

    // MARK: - Long vectors (the NEON u16 accumulators)

    /// Every bit of an 8 KiB pair differs, so the distance is 65536. The NEON path sums its u16 lanes
    /// per 2048 × 16-byte block, and a block of all-different bytes totals 262144: the reduction must
    /// widen, or the count wraps (to 0 here).
    @Test func `a long all-different pair counts every bit`() {
        let count = 8192
        let zeros = [UInt8](repeating: 0x00, count: count)
        let ones = [UInt8](repeating: 0xFF, count: count)
        #expect(Self.distance(zeros, ones, .fastest) == count * 8)
    }

    /// The batched scan over one vector wider than 64 KiB counts every bit, like the single-pair call:
    /// each u16 lane gains 16 per 16 bytes, so without a per-block flush the lanes themselves wrap.
    @Test func `the batched scan counts every bit of a vector wider than 64 KiB`() {
        let width = 4097 * 16
        let query = [UInt8](repeating: 0x00, count: width)
        let corpus = [UInt8](repeating: 0xFF, count: width)
        var out: [UInt32] = [0]
        query.withUnsafeBufferPointer { pq in
            corpus.withUnsafeBufferPointer { pc in
                out.withUnsafeMutableBufferPointer { po in
                    guard let bq = pq.baseAddress, let bc = pc.baseAddress, let bo = po.baseAddress else { return }
                    AemiKernels.hammingScan(query: bq, corpus: bc, width: width, count: 1, into: bo)
                }
            }
        }
        #expect(out == [UInt32(width * 8)])
    }

    /// Random pairs at lengths around the 2048 × 16-byte NEON block boundary agree with the scalar
    /// reference — random bytes differ in about half their bits, which already overflows a u16 sum.
    @Test func `long random pairs match the scalar reference`() {
        var rng = SeededRNG(seed: 0x4A11_0B5E_55ED_2048)
        var mismatches = 0
        for count in [8191, 8192, 32752, 32768, 32784, 65536 + 17] {
            var a: [UInt8] = []
            var b: [UInt8] = []
            a.reserveCapacity(count)
            b.reserveCapacity(count)
            for _ in 0 ..< count {
                a.append(UInt8(rng.int(256)))
                b.append(UInt8(rng.int(256)))
            }
            if Self.distance(a, b, .fastest) != Self.distance(a, b, .scalar) { mismatches += 1 }
        }
        #expect(mismatches == 0)
    }

    @Test func fastestMatchesScalarAndReferenceFuzzed() {
        var rng = SeededRNG(seed: 0x0DDB_A11_C0FFEE_11)
        var mismatches = 0
        let widths = [0, 1, 7, 8, 9, 15, 16, 17, 31, 32, 33, 63, 64, 65, 100, 128, 257]
        for _ in 0 ..< 5000 {
            let width = widths[rng.int(widths.count)]
            var a: [UInt8] = []
            var b: [UInt8] = []
            a.reserveCapacity(width)
            b.reserveCapacity(width)
            for _ in 0 ..< width {
                a.append(UInt8(rng.int(256)))
                b.append(UInt8(rng.int(256)))
            }
            let expected = Self.referenceDistance(a, b)
            if Self.distance(a, b, .fastest) != expected { mismatches += 1 }
            if Self.distance(a, b, .scalar) != expected { mismatches += 1 }
        }
        #expect(mismatches == 0)
    }
}

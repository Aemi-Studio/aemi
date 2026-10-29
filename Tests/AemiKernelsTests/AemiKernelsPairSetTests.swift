import AemiKernels
import AemiTestKit
import Testing

/// `AemiKernels.PairSet` (promoted from AemiRegex, aemi ADR 0018) is a C (NEON, SSSE3, scalar) Teddy kernel: candidates come from
/// nibble lookups, so it may offer a position that is not a pair (buckets collide) but must never skip one that is.
struct AemiKernelsPairSetTests {
    private typealias Pair = (first: UInt8, second: UInt8)
    private static let maxPairCount = 16

    private static let sizes = [0, 1, 2, 16, 17, 18, 33, 63, 64, 65, 66, 127, 128, 129, 200, 513]

    private static func randomPairs(_ rng: inout SeededRNG, count: Int) -> [Pair] {
        let alphabet = Array("abcdefgxyz ABC_\n".utf8)
        return (0 ..< count)
            .map { _ in
                (
                    first: alphabet.randomElement(using: &rng) ?? 0x61,
                    second: alphabet.randomElement(using: &rng) ?? 0x62
                )
            }
    }

    private static func haystack(_ rng: inout SeededRNG, size: Int) -> [UInt8] {
        let alphabet = Array("abcdefgxyz ABC_\n12".utf8)
        return (0 ..< size).map { _ in alphabet.randomElement(using: &rng) ?? 0x61 }
    }

    @Test(arguments: sizes)
    func `the SIMD kernel returns exactly what the scalar reference returns, from every offset`(size: Int) {
        var rng = SeededRNG(seed: UInt64(size) &* 0x9E37 &+ 11)
        for round in 0 ..< 12 {
            let pairs = Self.randomPairs(&rng, count: 1 + round % Self.maxPairCount)
            let teddy = AemiKernels.PairSet(pairs)
            let bytes = Self.haystack(&rng, size: size)
            for from in 0 ... size {
                let simd = bytes.withUnsafeBufferPointer { teddy.firstCandidate(in: $0, from: from) }
                let scalar = bytes.withUnsafeBufferPointer {
                    teddy.firstCandidate(in: $0, from: from, backend: .scalar)
                }
                #expect(simd == scalar, "\(pairs.count) pairs from \(from) in \(size) bytes")
            }
        }
    }

    @Test(arguments: sizes)
    func `a candidate is never later than the first real pair, and none is offered when no pair exists`(size: Int) {
        var rng = SeededRNG(seed: UInt64(size) &* 0x51 &+ 3)
        for round in 0 ..< 12 {
            let pairs = Self.randomPairs(&rng, count: 1 + round % Self.maxPairCount)
            let teddy = AemiKernels.PairSet(pairs)
            let bytes = Self.haystack(&rng, size: size)
            let exact = (0 ..< max(0, size - 1))
                .first { index in
                    pairs.contains { $0.first == bytes[index] && $0.second == bytes[index + 1] }
                }
            let offered = bytes.withUnsafeBufferPointer { teddy.firstCandidate(in: $0, from: 0) }
            if let exact {
                #expect(offered != nil && offered! <= exact, "pair at \(exact), offered \(String(describing: offered))")
            }
            if let offered { #expect(offered + 1 < size, "a candidate needs two bytes") }
        }
    }

    @Test func `a start offset outside the buffer finds nothing`() {
        let teddy = AemiKernels.PairSet([(0x61, 0x62)])
        let bytes: [UInt8] = [0x61, 0x62]
        bytes.withUnsafeBufferPointer {
            #expect(teddy.firstCandidate(in: $0, from: 2) == nil)
            #expect(teddy.firstCandidate(in: $0, from: -1) == nil)
            #expect(teddy.firstCandidate(in: $0, from: 0) == 0)
        }
    }

    /// The bytes just past the end are made to look like a pair, so a kernel that reads past the end offers a position it must not.
    @Test(arguments: sizes)
    func `the kernel never reads or reports anything past the end of the buffer`(size: Int) {
        guard size > 0 else { return }
        let teddy = AemiKernels.PairSet([(0x61, 0x62), (0x62, 0x62)])
        var storage = [UInt8](repeating: 0x78, count: size)
        storage[size - 1] = 0x61
        storage += [UInt8](repeating: 0x62, count: 80)
        storage.withUnsafeBufferPointer { whole in
            let body = UnsafeBufferPointer(rebasing: whole[0 ..< size])
            #expect(teddy.firstCandidate(in: body, from: 0) == nil, "\(size) bytes")
        }
    }

    /// Every candidate the scalar reference finds, in order, collected by walking the buffer one candidate at a time.
    private static func allScalarCandidates(_ teddy: AemiKernels.PairSet, _ bytes: [UInt8], from: Int) -> [Int] {
        var found: [Int] = []
        var next = from
        while let candidate = bytes.withUnsafeBufferPointer({
            teddy.firstCandidate(in: $0, from: next, backend: .scalar)
        }) {
            found.append(candidate)
            next = candidate + 1
        }
        return found
    }

    @Test(arguments: sizes)
    func `the batch call lists every candidate once, in order, for any capacity and start`(size: Int) {
        var rng = SeededRNG(seed: UInt64(size) &* 0x77 &+ 5)
        for round in 0 ..< 10 {
            let pairs = Self.randomPairs(&rng, count: 1 + round % Self.maxPairCount)
            let teddy = AemiKernels.PairSet(pairs)
            let bytes = Self.haystack(&rng, size: size)
            for from in [0, size / 3, size] {
                let expected = Self.allScalarCandidates(teddy, bytes, from: from)
                for capacity in [1, 5, 16, 17, 33, 64, 65, 256] {
                    var collected: [Int] = []
                    var resume = from
                    var guardCount = 0
                    while resume < size, guardCount < size + 4 {
                        guardCount += 1
                        var out = [Int](repeating: -7, count: capacity + 3)  // a guard band after `capacity` entries
                        let (count, next) = out.withUnsafeMutableBufferPointer { buffer in
                            bytes.withUnsafeBufferPointer {
                                teddy.candidates(
                                    in: $0, from: resume,
                                    into: UnsafeMutableBufferPointer<Int>(rebasing: buffer[0 ..< capacity]))
                            }
                        }
                        #expect(count <= capacity, "wrote more than the capacity")
                        #expect(out[capacity...].allSatisfy { $0 == -7 }, "wrote past the capacity")
                        collected += out[0 ..< count]
                        #expect(next > resume || next >= size, "no progress from \(resume)")
                        resume = next
                    }
                    #expect(
                        collected == expected, "\(pairs.count) pairs, capacity \(capacity), from \(from), \(size) bytes"
                    )
                }
            }
        }
    }

    @Test(arguments: sizes)
    func `the batch call never reads or reports anything past the end of the buffer`(size: Int) {
        guard size > 0 else { return }
        let teddy = AemiKernels.PairSet([(0x61, 0x62), (0x62, 0x62)])
        var storage = [UInt8](repeating: 0x78, count: size)
        storage[size - 1] = 0x61
        storage += [UInt8](repeating: 0x62, count: 80)
        storage.withUnsafeBufferPointer { whole in
            let body = UnsafeBufferPointer(rebasing: whole[0 ..< size])
            var out = [Int](repeating: 0, count: 64)
            let (count, _) = out.withUnsafeMutableBufferPointer { teddy.candidates(in: body, from: 0, into: $0) }
            #expect(count == 0, "\(size) bytes: a candidate past the end was reported")
        }
    }

    /// When every position is a candidate the output buffer fills in every call: this is the case that can overrun it. The pair set
    /// accepts any two bytes of {a, b}, so a haystack of only a and b makes every position but the last a candidate.
    @Test(arguments: sizes)
    func `a haystack where every position is a candidate fills any capacity without writing past it`(size: Int) {
        guard size >= 2 else { return }
        let teddy = AemiKernels.PairSet([(0x61, 0x61), (0x61, 0x62), (0x62, 0x61), (0x62, 0x62)])
        var rng = SeededRNG(seed: UInt64(size))
        let bytes: [UInt8] = (0 ..< size).map { _ in Bool.random(using: &rng) ? 0x61 : 0x62 }
        for capacity in [1, 2, 15, 16, 17, 63, 64, 65, 100, 256] {
            var collected: [Int] = []
            var resume = 0
            while resume < size {
                var out = [Int](repeating: -7, count: capacity + 8)
                let (count, next) = out.withUnsafeMutableBufferPointer { buffer in
                    bytes.withUnsafeBufferPointer {
                        teddy.candidates(
                            in: $0, from: resume,
                            into: UnsafeMutableBufferPointer<Int>(rebasing: buffer[0 ..< capacity]))
                    }
                }
                #expect(count <= capacity, "capacity \(capacity): wrote \(count)")
                #expect(out[capacity...].allSatisfy { $0 == -7 }, "capacity \(capacity): wrote past it")
                collected += out[0 ..< count]
                resume = next
            }
            #expect(collected == Array(0 ..< size - 1), "capacity \(capacity), \(size) bytes")
        }
    }
}

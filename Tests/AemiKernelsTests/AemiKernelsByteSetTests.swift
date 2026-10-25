import AemiKernels
import Testing

// The nibble-table set scan: the facade builds the tables exactly or refuses, and every backend agrees with an independent loop over the set.
struct AemiKernelsByteSetTests {
    struct Generator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// A set with at most three rows, so it always fits.
    static func fittingSet(seed: UInt64) -> Set<UInt8> {
        var generator = Generator(state: seed)
        var set = Set<UInt8>()
        for _ in 0 ..< 3 {
            let upper = UInt8.random(in: 0 ... 15, using: &generator)
            for lower in UInt8(0) ... 15 where Int.random(in: 0 ..< 4, using: &generator) == 0 {
                set.insert(upper << 4 | lower)
            }
        }
        return set
    }

    @Test(arguments: 0 ..< 200)
    func `the tables hold a set that fits exactly, for every byte value`(seed: Int) throws {
        let set = Self.fittingSet(seed: UInt64(seed))
        let table = try #require(AemiKernels.ByteSet(set))
        for byte in UInt8.min ... UInt8.max {
            #expect(table.contains(byte) == set.contains(byte), "byte \(byte) of seed \(seed)")
        }
    }

    @Test func `a set with nine distinct rows is refused`() {
        // Nine upper nibbles, each with a different lower nibble: nine rows.
        let bytes = (0 ..< 9).map { UInt8($0 << 4 | $0) }
        #expect(AemiKernels.ByteSet(bytes) == nil)
        // The same nine upper nibbles with one shared lower nibble are one row.
        #expect(AemiKernels.ByteSet((0 ..< 9).map { UInt8($0 << 4 | 3) }) != nil)
    }

    @Test func `the empty set and the full alphabet are held`() throws {
        let empty = try #require(AemiKernels.ByteSet([UInt8]()))
        #expect(!(0 ... 255).contains { empty.contains(UInt8($0)) })
        let full = try #require(AemiKernels.ByteSet(0 ... 255 as ClosedRange<UInt8>))
        #expect((0 ... 255).allSatisfy { full.contains(UInt8($0)) })
    }

    @Test(arguments: [AemiKernels.Backend.fastest, .scalar, .neon, .sse2, .avx2], 0 ..< 60)
    func `every backend finds the first byte of the set at every position`(backend: AemiKernels.Backend, seed: Int)
        throws
    {
        let set = Self.fittingSet(seed: UInt64(seed) &+ 1_000)
        let table = try #require(AemiKernels.ByteSet(set))
        var generator = Generator(state: UInt64(seed))
        let members = Array(set)
        for length in [0, 1, 7, 8, 15, 16, 17, 31, 33, 63, 64, 65, 79, 80, 127, 300] {
            var bytes = (0 ..< length).map { _ in UInt8.random(in: 0 ... 255, using: &generator) }
                .filter { !set.contains($0) }
            while bytes.count < length { bytes.append(UInt8(0x41)) }
            bytes = bytes.map { set.contains($0) ? 0x41 : $0 }
            if set.contains(0x41) { continue }
            #expect(AemiKernels.firstIndex(inSet: table, in: bytes, backend: backend) == nil)
            guard !members.isEmpty else { continue }
            for hit in stride(from: 0, to: length, by: Swift.max(1, length / 7)) {
                var planted = bytes
                planted[hit] = members[hit % members.count]
                if hit + 1 < length {
                    planted[hit + 1 + Int.random(in: 0 ..< (length - hit - 1), using: &generator)] = members[0]
                }
                let expected = planted.firstIndex { set.contains($0) }
                #expect(
                    AemiKernels.firstIndex(inSet: table, in: planted, backend: backend) == expected,
                    "length \(length), hit \(hit)")
            }
        }
    }
}

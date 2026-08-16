import Testing

@testable import AemiTestKit

/// A standalone re-implementation of the legacy `SplitMix64`, kept here as the
/// reference stream `SeededRNG` must reproduce byte-for-byte (so a migrated fuzz
/// corpus is unchanged under the same seed).
private struct LegacySplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite(.tags(.property))
struct SeededRNGTests {
    @Test
    func `core stream is identical to the legacy SplitMix64`() {
        for seed: UInt64 in [0, 1, 0x5DEE_CE66_D0DC_2F1B, 0xADDB_F0E5_1234_5678, .max] {
            var kit = SeededRNG(seed: seed)
            var legacy = LegacySplitMix64(seed: seed)
            for _ in 0 ..< 10_000 {
                #expect(kit.next() == legacy.next())
            }
        }
    }

    @Test
    func `same seed reproduces the same sequence`() {
        var a = SeededRNG(seed: 0xABCD_1234_5678_9F01)
        var b = SeededRNG(seed: 0xABCD_1234_5678_9F01)
        for _ in 0 ..< 1000 {
            #expect(a.next() == b.next())
        }
    }

    @Test
    func `the three bounded-int spellings are one implementation`() {
        // Three RNGs seeded identically must produce identical bounded draws across the
        // three legacy names, since they share one core.
        var byUpTo = SeededRNG(seed: 7)
        var byBelow = SeededRNG(seed: 7)
        var byInt = SeededRNG(seed: 7)
        for bound in 1 ... 64 {
            let u = byUpTo.next(upTo: bound)
            let b = byBelow.below(bound)
            let i = byInt.int(bound)
            #expect(u == b)
            #expect(b == i)
            #expect((0 ..< bound).contains(u))
        }
    }

    @Test
    func `int(in:) replicates lower + uniform(width)`() {
        var rng = SeededRNG(seed: 99)
        var reference = SeededRNG(seed: 99)
        let range = -5 ... 5
        for _ in 0 ..< 1000 {
            let drawn = rng.int(in: range)
            let expected =
                range.lowerBound + reference.uniform(range.upperBound - range.lowerBound + 1)
            #expect(drawn == expected)
            #expect(range.contains(drawn))
        }
    }

    @Test
    func `int(in:) handles extreme ranges without trapping and stays in bounds`() {
        // The naive `upper - lower + 1` traps on overflow for any of these; the unsigned
        // span keeps every draw in range. (A regression here would crash, not just fail.)
        var rng = SeededRNG(seed: 0x1234_ABCD)
        let ranges: [ClosedRange<Int>] = [
            Int.min ... Int.max,
            0 ... Int.max,
            Int.min ... 0,
            Int.min ... (Int.min + 1),
            (Int.max - 1) ... Int.max
        ]
        for range in ranges {
            for _ in 0 ..< 1000 { #expect(range.contains(rng.int(in: range))) }
        }
    }

    @Test
    func `bool / byte match the legacy derivations`() {
        var kit = SeededRNG(seed: 0xDEAD_BEEF)
        var legacy = LegacySplitMix64(seed: 0xDEAD_BEEF)
        for _ in 0 ..< 1000 {
            #expect(kit.bool() == (legacy.next() & 1 == 0))
        }
        for _ in 0 ..< 1000 {
            #expect(kit.byte() == UInt8(truncatingIfNeeded: legacy.next()))
        }
    }

    @Test
    func `pick selects an in-bounds element deterministically`() {
        let items = Array(100 ..< 140)
        var a = SeededRNG(seed: 3)
        var b = SeededRNG(seed: 3)
        for _ in 0 ..< 500 {
            let x = a.pick(items)
            let y = b.pick(items)
            #expect(x == y)
            #expect(items.contains(x))
        }
    }

    @Test
    func `Seed.named is stable and process-independent`() {
        // Same name → same value every run (FNV-1a, not Hasher).
        #expect(Seed.named("addb.corrupt-file") == Seed.named("addb.corrupt-file"))
        #expect(Seed.named("a") != Seed.named("b"))
        // Pin a concrete value so a future change to the derivation is caught.
        #expect(Seed.named("").rawValue == 0xCBF2_9CE4_8422_2325)
        // FNV-1a of a single byte 'a' (0x61): (offset ^ 0x61) * prime.
        let expectedA = (0xCBF2_9CE4_8422_2325 ^ UInt64(0x61)) &* 0x0000_0100_0000_01B3
        #expect(Seed.named("a").rawValue == expectedA)
    }

    @Test
    func `seeding by Seed and by raw UInt64 agree`() {
        var byRaw = SeededRNG(seed: 0x1234_5678)
        var bySeed = SeededRNG(seed: Seed(0x1234_5678))
        for _ in 0 ..< 100 { #expect(byRaw.next() == bySeed.next()) }
    }
}

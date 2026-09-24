import AemiKernel
import AemiTestKit
import Testing

// The SWAR predicates promise the first matching lane, not every lane: the borrow out of a matching
// lane may flag the lane above it. Each check compares a mask with a lane-by-lane reference: zero iff
// no byte matches, else the lowest flagged bit is the `0x80` bit of the first matching byte. Words are
// built from bytes around the predicate's boundary, where the borrows happen.
struct SWARTests {
    /// The little-endian index of the first byte of `word` satisfying `matches`, or `nil`.
    static func firstMatch(_ word: UInt64, _ matches: (UInt8) -> Bool) -> Int? {
        for lane in 0 ..< 8 where matches(UInt8(truncatingIfNeeded: word >> (8 * lane))) { return lane }
        return nil
    }

    /// Whether `mask` reports exactly the first match: nothing when there is none, else its `0x80` bit.
    static func reportsFirstMatch(_ mask: UInt64, _ first: Int?) -> Bool {
        guard let first else { return mask == 0 }
        return mask.trailingZeroBitCount == 8 * first + 7
    }

    /// A word whose bytes are drawn from `pivot - 1`, `pivot`, `pivot + 1` and a few fixed extremes.
    static func word(around pivot: UInt8, _ rng: inout SeededRNG) -> UInt64 {
        let choices: [UInt8] = [pivot &- 1, pivot, pivot &+ 1, 0x00, 0x01, 0x7F, 0x80, 0xFF]
        var word: UInt64 = 0
        for lane in 0 ..< 8 {
            word |= UInt64(choices[rng.int(choices.count)]) << (8 * lane)
        }
        return word
    }

    @Test func `lessThan reports the first byte below the bound`() {
        var rng = SeededRNG(seed: 0x5EA2_1E55_7A40_0001)
        var mismatches = 0
        for bound in UInt8(0) ... 0x80 {
            for _ in 0 ..< 400 {
                let word = Self.word(around: bound, &rng)
                let first = Self.firstMatch(word) { $0 < bound }
                if !Self.reportsFirstMatch(SWAR.lessThan(word, bound), first) { mismatches += 1 }
            }
        }
        #expect(mismatches == 0)
    }

    @Test func `equals reports the first equal byte`() {
        var rng = SeededRNG(seed: 0x5EA2_E0A1_5000_0002)
        var mismatches = 0
        for target in UInt8.min ... UInt8.max {
            for _ in 0 ..< 200 {
                let word = Self.word(around: target, &rng)
                let first = Self.firstMatch(word) { $0 == target }
                if !Self.reportsFirstMatch(SWAR.equals(word, target), first) { mismatches += 1 }
            }
        }
        #expect(mismatches == 0)
    }

    @Test func `nonASCII flags every non-ASCII byte`() {
        var rng = SeededRNG(seed: 0x5EA2_A5C1_1000_0003)
        var mismatches = 0
        for _ in 0 ..< 20_000 {
            let word = Self.word(around: 0x80, &rng)
            var expected: UInt64 = 0
            for lane in 0 ..< 8 where UInt8(truncatingIfNeeded: word >> (8 * lane)) >= 0x80 {
                expected |= 0x80 << (8 * lane)
            }
            if SWAR.nonASCII(word) != expected { mismatches += 1 }
        }
        #expect(mismatches == 0)
    }
}

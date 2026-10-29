import AemiUnicode
import Testing

/// `UnicodeScalarSet`, promoted from AemiRegex (aemi ADR 0018): sorted, merged ranges, and the set algebra a class needs. Each operation
/// is checked against plain `Set<UInt32>` arithmetic over a small universe.
struct UnicodeScalarSetTests {
    private static let universe: ClosedRange<UInt32> = 0 ... 40

    private static func members(_ set: UnicodeScalarSet) -> Set<UInt32> {
        Set(set.ranges.flatMap { Array($0) }.filter { universe.contains($0) })
    }

    private static let samples: [UnicodeScalarSet] = [
        UnicodeScalarSet(), UnicodeScalarSet(7),
        UnicodeScalarSet(normalizing: [3 ... 9, 8 ... 12, 20 ... 20, 21 ... 22]),
        UnicodeScalarSet(normalizing: [0 ... 0, 40 ... 40]), UnicodeScalarSet(normalizing: [10 ... 30])
    ]

    @Test func `ranges are sorted, merged when they touch or overlap, and never adjacent`() {
        let set = UnicodeScalarSet(normalizing: [20 ... 20, 3 ... 9, 21 ... 22, 8 ... 12])
        #expect(set.ranges == [3 ... 12, 20 ... 22])
        #expect(UnicodeScalarSet(normalizing: [5 ... 5, 6 ... 6]).ranges == [5 ... 6])
    }

    @Test func `membership, union, intersection, difference and negation agree with set arithmetic`() {
        for a in Self.samples {
            for value in Self.universe {
                #expect(a.contains(value) == Self.members(a).contains(value), "\(a) \(value)")
            }
            #expect(Self.members(a.negated()) == Set(Self.universe).subtracting(Self.members(a)), "not \(a)")
            #expect(a.negated().negated() == a)
            for b in Self.samples {
                #expect(Self.members(a.union(b)) == Self.members(a).union(Self.members(b)))
                #expect(Self.members(a.intersection(b)) == Self.members(a).intersection(Self.members(b)))
                #expect(Self.members(a.subtracting(b)) == Self.members(a).subtracting(Self.members(b)))
            }
        }
    }

    @Test func `negation covers the whole scalar range`() {
        #expect(UnicodeScalarSet().negated().ranges == [0 ... UnicodeScalarSet.maxScalar])
        #expect(UnicodeScalarSet(normalizing: [0 ... 0x10FFFF]).negated().isEmpty)
    }
}

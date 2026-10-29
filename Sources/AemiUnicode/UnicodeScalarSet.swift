/// A set of Unicode scalar values, kept as sorted, non-adjacent closed ranges: what a property, a category or a class is. Promoted
/// from AemiRegex with the tables it is read from (aemi ADR 0018).
public struct UnicodeScalarSet: Equatable, Hashable, Sendable {
    /// The largest scalar value.
    public static let maxScalar: UInt32 = 0x10FFFF

    /// The members, as sorted, non-adjacent, non-overlapping closed ranges.
    public private(set) var ranges: [ClosedRange<UInt32>]

    public init() { ranges = [] }

    public init(_ scalar: UInt32) { ranges = [scalar ... scalar] }

    /// Builds a set from unordered, possibly overlapping ranges.
    public init(normalizing input: [ClosedRange<UInt32>]) {
        var merged: [ClosedRange<UInt32>] = []
        merged.reserveCapacity(input.count)
        for range in input.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, range.lowerBound <= last.upperBound &+ 1 {
                if range.upperBound > last.upperBound {
                    merged[merged.count - 1] = last.lowerBound ... range.upperBound
                }
            } else {
                merged.append(range)
            }
        }
        ranges = merged
    }

    public var isEmpty: Bool { ranges.isEmpty }

    /// Whether `value` is in the set.
    /// - Complexity: O(log ranges).
    public func contains(_ value: UInt32) -> Bool {
        var low = 0
        var high = ranges.count - 1
        while low <= high {
            let middle = (low + high) / 2
            if value < ranges[middle].lowerBound {
                high = middle - 1
            } else if value > ranges[middle].upperBound {
                low = middle + 1
            } else {
                return true
            }
        }
        return false
    }

    public func union(_ other: UnicodeScalarSet) -> UnicodeScalarSet {
        UnicodeScalarSet(normalizing: ranges + other.ranges)
    }

    /// Every scalar value in `0 ... 0x10FFFF` that is not in the set. Surrogates are left in: no UTF-8 sequence encodes them, so a
    /// byte-level compiler drops them.
    public func negated() -> UnicodeScalarSet {
        var result: [ClosedRange<UInt32>] = []
        result.reserveCapacity(ranges.count + 1)
        var next: UInt32 = 0
        for range in ranges {
            if range.lowerBound > next { result.append(next ... range.lowerBound - 1) }
            next = range.upperBound &+ 1
        }
        if next <= Self.maxScalar { result.append(next ... Self.maxScalar) }
        return UnicodeScalarSet(normalizing: result)
    }

    /// The scalars in both sets.
    /// - Complexity: O(ranges of both).
    public func intersection(_ other: UnicodeScalarSet) -> UnicodeScalarSet {
        var result: [ClosedRange<UInt32>] = []
        var left = 0
        var right = 0
        while left < ranges.count, right < other.ranges.count {
            let (a, b) = (ranges[left], other.ranges[right])
            let low = max(a.lowerBound, b.lowerBound)
            let high = min(a.upperBound, b.upperBound)
            if low <= high { result.append(low ... high) }
            if a.upperBound < b.upperBound { left += 1 } else { right += 1 }
        }
        return UnicodeScalarSet(normalizing: result)
    }

    /// The scalars in this set and not in `other`.
    public func subtracting(_ other: UnicodeScalarSet) -> UnicodeScalarSet { intersection(other.negated()) }

    /// The set plus every scalar that simple case folding relates to a member: for each orbit the set touches, all of the orbit
    /// (``CaseFolding/simpleOrbit(of:)``). A set of a few scalars looks each up; a larger one is checked against every orbit.
    /// - Complexity: O(scalars log orbits) for a small set, O(orbits log ranges) otherwise.
    public func simpleCaseClosure() -> UnicodeScalarSet {
        var extra: [ClosedRange<UInt32>] = []
        var size = 0
        for range in ranges { size += Int(range.upperBound - range.lowerBound) + 1 }
        if size <= 64 {
            for range in ranges {
                for value in range {
                    guard let orbit = CaseFolding.simpleOrbit(of: value) else { continue }
                    for member in orbit where !contains(member) { extra.append(member ... member) }
                }
            }
        } else {
            for orbit in CaseFolding.simpleOrbits where orbit.contains(where: { contains($0) }) {
                for member in orbit where !contains(member) { extra.append(member ... member) }
            }
        }
        return extra.isEmpty ? self : UnicodeScalarSet(normalizing: ranges + extra)
    }
}

//
//  Comparable+Clamped.swift
//  AemiCore
//

public extension Comparable {
    /// Returns this value clamped to `limits`.
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }

    /// Clamps this value to `limits` in place.
    mutating func clamp(to limits: ClosedRange<Self>) {
        self = clamped(to: limits)
    }
}

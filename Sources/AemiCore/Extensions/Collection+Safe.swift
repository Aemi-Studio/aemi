//
//  Collection+Safe.swift
//  AemiCore
//

public extension Collection {
    /// Returns the element at `index`, or `nil` when the index is out of
    /// bounds. The canonical replacement for the ad-hoc `[safe:]` helpers
    /// previously duplicated across apps.
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

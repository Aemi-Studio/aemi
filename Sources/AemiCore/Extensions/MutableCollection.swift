//
//  MutableCollection.swift
//  AemiCore
//
//  Created by Guillaume Coquard on 15/02/25.
//

public extension MutableCollection {
    /// Change the value at the specified index.
    /// Index is assumed valid.
    /// - Parameters:
    ///   - element: Element to set
    ///   - index: Index where to set the element
    private mutating func _set(_ element: Element, at index: Index) {
        self[index] = element
    }

    subscript(guard index: Index?) -> Element? {
        get {
            if let index = index, indices.contains([index]) {
                self[index]
            } else {
                nil
            }
        }
        set {
            guard let newValue, let index, indices.contains([index]) else { return }
            _set(newValue, at: index)
        }
    }
}

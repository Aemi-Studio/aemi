//
//  Collection.swift
//  AemiCore
//
//  Created by Guillaume Coquard on 15/02/25.
//

public extension Collection {
    subscript(guard index: Index?) -> Element? {
        if let index = index, indices.contains([index]) {
            self[index]
        } else {
            nil
        }
    }
}

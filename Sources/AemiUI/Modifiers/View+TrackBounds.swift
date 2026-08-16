//
//  View+TrackBounds.swift
//  AemiUI
//
//  Created by Guillaume Coquard on 29/03/25.
//

import SwiftUI

public extension View {
    func track(bounds: Binding<CGRect>, in coordinateSpace: CoordinateSpace = .global) -> some View {
        modifier(BoundsTrackerModifier(bounds: bounds, in: coordinateSpace))
    }
}

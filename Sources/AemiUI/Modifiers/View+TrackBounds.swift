//
//  View+TrackBounds.swift
//  AemiUI
//
//  Created by Gigi on 29/03/25.
//

#if canImport(SwiftUI)
    import SwiftUI

    extension View {
        public func track(bounds: Binding<CGRect>, in coordinateSpace: CoordinateSpace = .global) -> some View {
            modifier(BoundsTrackerModifier(bounds: bounds, in: coordinateSpace))
        }
    }
#endif

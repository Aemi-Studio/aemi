#if os(iOS)
//
//  View+VisibilityTracker.swift
//  AemiUI
//
//  Created by Guillaume Coquard on 29/03/25.
//

import SwiftUI

public extension View {
    func track(
        threshold: Double = 1,
        visibility: Binding<CGFloat>,
        isVisible: Binding<Bool>,
        coordinateSpace: CoordinateSpace = .global,
        in container: Binding<CGRect>? = nil
    ) -> some View {
        modifier(VisibilityTrackerModifier(
            threshold: threshold,
            coordinateSpace: coordinateSpace,
            isVisible: isVisible,
            visibility: visibility,
            containerBounds: container
        ))
    }

    func track(
        threshold: Double = 1,
        visibility: Binding<CGFloat>,
        coordinateSpace: CoordinateSpace = .global,
        in container: Binding<CGRect>? = nil
    ) -> some View {
        modifier(VisibilityTrackerModifier(
            threshold: threshold,
            coordinateSpace: coordinateSpace,
            isVisible: .constant(false),
            visibility: visibility,
            containerBounds: container
        ))
    }

    func track(
        isVisible: Binding<Bool>,
        coordinateSpace: CoordinateSpace = .global,
        in container: Binding<CGRect>? = nil
    ) -> some View {
        modifier(VisibilityTrackerModifier(
            threshold: 1,
            coordinateSpace: coordinateSpace,
            isVisible: isVisible,
            visibility: .constant(0),
            containerBounds: container
        ))
    }
}
#endif

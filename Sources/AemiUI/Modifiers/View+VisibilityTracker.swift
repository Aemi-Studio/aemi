#if os(iOS)
    //
    //  View+VisibilityTracker.swift
    //  AemiUI
    //
    //  Created by Gigi on 29/03/25.
    //

    import SwiftUI

    extension View {
        public func track(
            threshold: Double = 1,
            visibility: Binding<CGFloat>,
            isVisible: Binding<Bool>,
            coordinateSpace: CoordinateSpace = .global,
            in container: Binding<CGRect>? = nil
        ) -> some View {
            modifier(
                VisibilityTrackerModifier(
                    threshold: threshold,
                    coordinateSpace: coordinateSpace,
                    isVisible: isVisible,
                    visibility: visibility,
                    containerBounds: container
                )
            )
        }

        public func track(
            threshold: Double = 1,
            visibility: Binding<CGFloat>,
            coordinateSpace: CoordinateSpace = .global,
            in container: Binding<CGRect>? = nil
        ) -> some View {
            modifier(
                VisibilityTrackerModifier(
                    threshold: threshold,
                    coordinateSpace: coordinateSpace,
                    isVisible: .constant(false),
                    visibility: visibility,
                    containerBounds: container
                )
            )
        }

        public func track(
            isVisible: Binding<Bool>,
            coordinateSpace: CoordinateSpace = .global,
            in container: Binding<CGRect>? = nil
        ) -> some View {
            modifier(
                VisibilityTrackerModifier(
                    threshold: 1,
                    coordinateSpace: coordinateSpace,
                    isVisible: isVisible,
                    visibility: .constant(0),
                    containerBounds: container
                )
            )
        }
    }
#endif

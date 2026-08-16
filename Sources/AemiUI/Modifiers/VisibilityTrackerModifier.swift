#if os(iOS)
//
//  VisibilityTrackerModifier.swift
//  AemiUI
//
//  Created by Guillaume Coquard on 29/03/25.
//

import SwiftUI
import UIKit

struct VisibilityTrackerModifier: ViewModifier {
    @State private var bounds: CGRect = .zero

    private let threshold: CGFloat
    private let coordinateSpace: CoordinateSpace
    @Binding private var isVisible: Bool
    @Binding private var visibility: CGFloat
    private let containerBounds: Binding<CGRect>?

    init(
        threshold: Double,
        coordinateSpace: CoordinateSpace,
        isVisible: Binding<Bool>,
        visibility: Binding<CGFloat>,
        containerBounds: Binding<CGRect>? = nil
    ) {
        self.threshold = threshold
        self.coordinateSpace = coordinateSpace
        _isVisible = isVisible
        _visibility = visibility
        self.containerBounds = containerBounds
    }

    func body(content: Content) -> some View {
        content
            .track(bounds: $bounds, in: coordinateSpace)
            .versionAgnosticOnChange(of: bounds) { bounds in
                updateVisibility(bounds: bounds, container: containerBounds?.wrappedValue)
            }
    }

    private func updateVisibility(bounds: CGRect, container: CGRect? = nil) {
        guard let container = container ?? UIApplication.currentScreen?.bounds else { return }

        let intersection = bounds.intersection(container)
        let visibleArea = intersection.width * intersection.height
        let viewArea = bounds.width * bounds.height

        let visibility = (viewArea > 0) ? (visibleArea / viewArea) : 0
        let isVisible = visibility >= threshold

        Task { @MainActor in
            self.visibility = min(max(visibility, 0), 1)
            self.isVisible = isVisible
        }
    }
}
#endif

//
//  BoundsTrackerModifier.swift
//  AemiUI
//
//  Created by Guillaume Coquard on 29/03/25.
//

import SwiftUI

struct BoundsTrackerModifier: ViewModifier {
    @Binding private var bounds: CGRect
    private let coordinateSpace: CoordinateSpace

    init(bounds: Binding<CGRect>, in coordinateSpace: CoordinateSpace) {
        _bounds = bounds
        self.coordinateSpace = coordinateSpace
    }

    private struct BoundsPreferenceKey: PreferenceKey {
        static let defaultValue = CGRect.zero
        static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
            value = nextValue()
        }
    }

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { contentGeometry in
                    Color.clear
                        .task { @MainActor in
                            bounds = contentGeometry.frame(in: coordinateSpace)
                        }
                        .preference(
                            key: BoundsPreferenceKey.self,
                            value: contentGeometry.frame(in: coordinateSpace)
                        )
                }
            )
            .onPreferenceChange(BoundsPreferenceKey.self) { bounds in
                Task { @MainActor in
                    self.bounds = bounds
                }
            }
    }
}

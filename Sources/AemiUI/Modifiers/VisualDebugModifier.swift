//
//  VisualDebugModifier.swift
//  AemiUI
//
//  Created by Guillaume Coquard on 26/01/25.
//

import SwiftUI

struct VisualDebugModifier: ViewModifier {
    private let color: Color
    private let showDimensions: Bool

    @State
    private var size: CGSize? = .zero

    init(_ color: Color, showDimensions: Bool = false) {
        self.color = color
        self.showDimensions = showDimensions
    }

    func body(content: Content) -> some View {
        addDimensionsOverlay {
            content
                .overlay {
                    GeometryReader { _ in
                        Rectangle()
                            .stroke(color, lineWidth: 0.5)
                            .foregroundStyle(.clear)
                            .background(color.opacity(0.15))
                            .allowsHitTesting(false)
                            .update($size)
                    }
                }
        }
    }

    @ViewBuilder
    private func addDimensionsOverlay(@ViewBuilder content: @escaping () -> some View) -> some View {
        if showDimensions {
            content()
                .overlay(alignment: .topTrailing) { sizeOverlay }
        } else {
            content()
        }
    }

    @ViewBuilder
    private var sizeOverlay: some View {
        HStack {
            Text(size!.width, format: .number.precision(.fractionLength(2)).locale(.autoupdatingCurrent))
                + Text("w × ")
                + Text(size!.height, format: .number.precision(.fractionLength(2)).locale(.autoupdatingCurrent))
                + Text("h")
        }
        .font(.caption2)
        .fontWidth(.condensed)
        .fontWeight(.bold)
        .shadow(color: .black, radius: 0.5)
        .padding(4)
        .foregroundStyle(.white)
        .background(color.opacity(0.4))
        .clipShape(.rect)
        .overlay {
            Rectangle()
                .stroke(color.opacity(0.4), lineWidth: 0.5)
                .foregroundStyle(.clear)
        }
    }
}

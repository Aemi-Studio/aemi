//
//  ObservingCheckbox.swift
//  AemiUI
//
//  Created by Guillaume Coquard on 28/01/25.
//


import SwiftUI

public struct ObservingCheckbox<T>: View {
    private let value: T
    private let symbolProvider: (T) -> CheckboxSymbol?
    private let backgroundStyleProvider: (T) -> any ShapeStyle

    public init(
        value: T,
        symbolProvider: @escaping (T) -> CheckboxSymbol?,
        backgroundStyleProvider: @escaping (T) -> any ShapeStyle
    ) {
        self.value = value
        self.symbolProvider = symbolProvider
        self.backgroundStyleProvider = backgroundStyleProvider
    }

    @ScaledMetric
    private var size: CGFloat = 24

    private var symbol: String? {
        symbolProvider(value)?.rawValue
    }

    private var backgroundStyle: AnyShapeStyle {
        AnyShapeStyle(backgroundStyleProvider(value))
    }

    private var isKnown: Bool {
        symbol != nil
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .foregroundStyle(backgroundStyle)
            .frame(width: size, height: size)
            .if(isKnown) {
                $0.overlay {
                    Image(systemName: symbol!)
                        .foregroundStyle(.white)
                        .font(.callout)
                        .fontWeight(.bold)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.primary.quaternary, lineWidth: 0.5)
            }
    }
}

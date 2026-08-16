//
//  BooleanCheckbox.swift
//  AemiUI
//
//  Created by Guillaume Coquard on 28/01/25.
//

import SwiftUI

public struct BooleanCheckbox: View {
    @Binding private(set) var isOn: Bool

    private var tint: Color? {
        .accentColor
    }

    private func symbol(for status: Bool) -> CheckboxSymbol? {
        switch status {
        case true: .checkmark
        case false: nil
        }
    }

    private func backgroundStyle(for status: Bool) -> any ShapeStyle {
        switch status {
        case false: .gray.secondary
        case true: tint ?? .green
        }
    }

    public var body: some View {
        ObservingCheckbox(
            value: isOn,
            symbolProvider: symbol,
            backgroundStyleProvider: backgroundStyle
        )
    }
}

//
//  NativeToggleCheckboxStyle.swift
//  AemiUI
//
//  Created by Guillaume Coquard on 28/01/25.
//

import SwiftUI

public struct NativeToggleCheckboxStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    private enum ToggleValue: Sendable {
        case on
        case off
        case mixed

        init(from configuration: ToggleStyleConfiguration) {
            self = if configuration.isOn {
                .on
            } else if configuration.isMixed {
                .mixed
            } else {
                .off
            }
        }
    }

    public enum Placement: Sendable {
        case leading
        case trailing
    }

    var tint: Color? {
        .accentColor
    }

    var placement: Placement = .leading
    var spacing: CGFloat?

    private var computedSpacing: CGFloat { spacing != nil ? spacing! : placement == .leading ? 8 : 0 }

    private func makePlacement(configuration: Configuration) -> some View {
        HStack(spacing: spacing) {
            if placement == .trailing {
                configuration.label
                Spacer()
                ObservingCheckbox(
                    value: ToggleValue(from: configuration),
                    symbolProvider: symbol,
                    backgroundStyleProvider: backgroundStyle
                )
            } else {
                ObservingCheckbox(
                    value: ToggleValue(from: configuration),
                    symbolProvider: symbol,
                    backgroundStyleProvider: backgroundStyle
                )
                configuration.label
                Spacer()
            }
        }
        .padding(0)
    }

    public func makeBody(configuration: Configuration) -> some View {
        makePlacement(configuration: configuration)
            .contentShape(.rect)
            .onTapGesture {
                if isEnabled {
                    configuration.$isOn.wrappedValue.toggle()
                }
            }
    }

    private func symbol(for value: ToggleValue) -> CheckboxSymbol? {
        switch value {
        case .on: .checkmark
        case .off: nil
        case .mixed: .minus
        }
    }

    private func backgroundStyle(for value: ToggleValue) -> any ShapeStyle {
        switch value {
        case .on: tint ?? Color.green
        case .off: Color.gray.secondary
        case .mixed: Color.gray
        }
    }
}

public extension ToggleStyle where Self == NativeToggleCheckboxStyle {
    static var nativeCheckbox: some ToggleStyle {
        NativeToggleCheckboxStyle()
    }

    static func nativeCheckbox(placement: Self.Placement = .leading, spacing: CGFloat? = nil) -> some ToggleStyle {
        NativeToggleCheckboxStyle(
            placement: placement,
            spacing: spacing
        )
    }
}

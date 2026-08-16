//
//  IfModifier.swift
//  AemiUI
//
//  Created by Guillaume Coquard on 28/01/25.
//

import SwiftUI

public extension View {
    @ViewBuilder
    func `if`(_ condition: Bool...) -> some View {
        if condition.allSatisfy({ $0 }) {
            self
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    func `if`(_ condition: Bool, @ViewBuilder modifier: @escaping (Self) -> some View) -> some View {
        if condition {
            modifier(self)
        } else {
            self
        }
    }

    @ViewBuilder
    func `if`(
        _ condition: Bool,
        @ViewBuilder modifier: @escaping (Self) -> some View,
        @ViewBuilder else elseModifier: @escaping (Self) -> some View
    ) -> some View {
        if condition {
            modifier(self)
        } else {
            elseModifier(self)
        }
    }

    @ViewBuilder
    func `if`(_ condition: Binding<Bool>, @ViewBuilder modifier: @escaping (Self) -> some View) -> some View {
        if condition.wrappedValue {
            modifier(self)
        } else {
            self
        }
    }

    @ViewBuilder
    func `if`(
        _ condition: Binding<Bool>,
        @ViewBuilder modifier: @escaping (Self) -> some View,
        @ViewBuilder else elseModifier: @escaping (Self) -> some View
    ) -> some View {
        if condition.wrappedValue {
            modifier(self)
        } else {
            elseModifier(self)
        }
    }
}

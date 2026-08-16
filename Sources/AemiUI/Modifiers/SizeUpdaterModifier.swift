//
//  SizeUpdaterModifier.swift
//  AemiUI
//
//  Created by Guillaume Coquard on 26/01/25.
//

import SwiftUI

struct SizeUpdaterModifier: ViewModifier {
    @Binding private(set) var size: SizeKey.Value

    init(size: Binding<SizeKey.Value?>) {
        _size = Binding<SizeKey.Value> {
            size.wrappedValue ?? CGSize.zero
        } set: {
            size.wrappedValue = $0
        }
    }

    init(size: Binding<SizeKey.Value>) {
        _size = size
    }

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { proxy in
                    Color.clear
                        .preference(key: SizeKey.self, value: proxy.size)
                        .onPreferenceChange(SizeKey.self) { value in Task { @MainActor in size = value } }
                        .onAppear { size = proxy.size }
                }
            }
    }

    struct SizeKey: PreferenceKey {
        typealias Value = CGSize
        static let defaultValue: Value = .zero
        static func reduce(value: inout Value, nextValue: () -> Value) {
            value = nextValue()
        }
    }
}

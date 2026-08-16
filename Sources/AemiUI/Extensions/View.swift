//
//  View.swift
//  AemiUI
//
//  Created by Guillaume Coquard on 29/03/25.
//

import SwiftUI

extension View {
    @ViewBuilder func versionAgnosticOnChange<T: Equatable>(
        of value: T,
        perform action: @escaping (T) -> Void
    ) -> some View {
        if #available(iOS 17.0, *) {
            onChange(of: value) { _, newValue in action(newValue) }
        } else {
            onChange(of: value) { newValue in action(newValue) }
        }
    }
}

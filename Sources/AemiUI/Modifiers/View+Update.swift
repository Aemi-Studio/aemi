#if os(iOS)
//
//  View+Update.swift
//  AemiUI
//
//  Created by Guillaume Coquard on 26/01/25.
//

import Combine
import SwiftUI

public extension View {
    func update(keyboardSize: Binding<CGFloat?>) -> some View {
        onReceive(Publishers.keyboardHeight) { keyboardSize.wrappedValue = $0 }
    }
}
#endif

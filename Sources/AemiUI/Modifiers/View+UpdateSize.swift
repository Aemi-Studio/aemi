//
//  View+UpdateSize.swift
//  AemiUI
//
//  Created by Guillaume Coquard on 26/01/25.
//

import SwiftUI

public extension View {
    func update(_ size: Binding<CGSize>) -> some View {
        modifier(SizeUpdaterModifier(size: size))
    }

    func update(_ size: Binding<CGSize?>) -> some View {
        modifier(SizeUpdaterModifier(size: size))
    }
}

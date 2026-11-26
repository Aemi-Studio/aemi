//
//  View+UpdateSize.swift
//  AemiUI
//
//  Created by Gigi on 26/01/25.
//

#if canImport(SwiftUI)
    import SwiftUI

    extension View {
        public func update(_ size: Binding<CGSize>) -> some View {
            modifier(SizeUpdaterModifier(size: size))
        }

        public func update(_ size: Binding<CGSize?>) -> some View {
            modifier(SizeUpdaterModifier(size: size))
        }
    }
#endif

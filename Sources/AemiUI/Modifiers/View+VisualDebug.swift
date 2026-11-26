//
//  View+VisualDebug.swift
//  AemiUI
//
//  Created by Gigi on 26/01/25.
//

#if canImport(SwiftUI)
    import SwiftUI

    extension View {
        public func debug(_ color: Color = .red, showDimensions: Bool = false) -> some View {
            modifier(VisualDebugModifier(color, showDimensions: showDimensions))
        }
    }
#endif

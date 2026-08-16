#if os(iOS)
//
//  EdgeInsets.swift
//  AemiUI
//
//  Created by Guillaume Coquard on 04/02/25.
//

import SwiftUI
import UIKit

@MainActor
public extension EdgeInsets {
    static var safeAreaInsets: EdgeInsets {
        if let windowScene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
            let insets = windowScene.windows.first(where: { $0.isKeyWindow })?.safeAreaInsets
        {
            EdgeInsets(
                top: insets.top,
                leading: insets.left,
                bottom: insets.bottom,
                trailing: insets.right
            )
        } else {
            EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
        }
    }
}
#endif

#if os(iOS)
//
//  UIApplication.swift
//  AemiUI
//
//  Created by Guillaume Coquard on 29/03/25.
//

import UIKit

extension UIApplication {
    static var currentScene: UIWindowScene? {
        UIApplication
            .shared
            .connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .sorted { $0.activationState.rawValue < $1.activationState.rawValue }
            .first?
            .windows
            .filter(\.isKeyWindow)
            .first?
            .windowScene
    }

    static var currentScreen: UIScreen? {
        currentScene?.screen
    }
}
#endif

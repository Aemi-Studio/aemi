#if os(iOS)
//
//  Notification.swift
//  AemiUI
//
//  Created by Guillaume Coquard on 26/01/25.
//

import UIKit

extension Notification {
    var keyboardHeight: CGFloat {
        return (userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect)?
            .height ?? 0
    }
}
#endif

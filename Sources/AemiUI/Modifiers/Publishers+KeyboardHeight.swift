#if os(iOS)
//
//  Publishers+KeyboardHeight.swift
//  AemiUI
//
//  Created by Guillaume Coquard on 26/01/25.
//

import Combine
import UIKit

extension Publishers {
    static var keyboardHeight: AnyPublisher<CGFloat, Never> {
        let willShow = NotificationCenter.default.publisher(
            for: UIApplication.keyboardWillShowNotification
        )
        .map { $0.keyboardHeight }

        let willHide = NotificationCenter.default.publisher(
            for: UIApplication.keyboardWillHideNotification
        )
        .map { _ in CGFloat(0) }

        return MergeMany(willShow, willHide)
            .eraseToAnyPublisher()
    }

    static var asyncKeyboardHeight: AsyncStream<CGFloat> {
        let willShow = NotificationCenter.default.publisher(
            for: UIApplication.keyboardWillShowNotification
        )
        .map { $0.keyboardHeight }

        let willHide = NotificationCenter.default.publisher(
            for: UIApplication.keyboardWillHideNotification
        )
        .map { _ in CGFloat(0) }

        return MergeMany(willShow, willHide).stream
    }
}
#endif

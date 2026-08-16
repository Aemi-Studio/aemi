//
//  Platform.swift
//  AemiCore
//
//  Created by Guillaume Coquard on 10/03/25.
//

import Foundation

#if canImport(UIKit)
    import UIKit
#endif

@MainActor
public enum Platform {
    case pad
    case phone
    case mac
    case watch
    case tv
    case car
    case vision
    case unknown

    public static func `is`(_ target: Self) -> Bool {
        target == .current
    }

    public static var current: Platform {
        #if os(macOS)
            .mac
        #elseif os(watchOS)
            .watch
        #elseif os(tvOS)
            .tv
        #else
            switch UIDevice.current.userInterfaceIdiom {
            case .phone:
                .phone
            case .pad:
                .pad
            case .tv:
                .tv
            case .carPlay:
                .car
            case .mac:
                .mac
            case .vision:
                .vision
            case .unspecified:
                .unknown
            @unknown default:
                .unknown
            }
        #endif
    }
}

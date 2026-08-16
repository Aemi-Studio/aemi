//
//  Color+Hex.swift
//  AemiUI
//

import SwiftUI

public extension Color {
    /// Creates a color from a hexadecimal string — the canonical
    /// implementation of the `Color(hex:)` helper previously duplicated
    /// across apps.
    ///
    /// Accepts an optional `#` prefix and 3 (RGB), 4 (RGBA), 6 (RRGGBB)
    /// or 8 (RRGGBBAA) hexadecimal digits. Returns `nil` for anything else.
    init?(hex: String) {
        var digits = Substring(hex)
        if digits.hasPrefix("#") { digits = digits.dropFirst() }

        func expand(_ nibble: UInt64) -> Double {
            Double(nibble * 17) / 255
        }

        guard let value = UInt64(digits, radix: 16) else { return nil }

        let red, green, blue, opacity: Double
        switch digits.count {
        case 3:
            red = expand((value >> 8) & 0xF)
            green = expand((value >> 4) & 0xF)
            blue = expand(value & 0xF)
            opacity = 1
        case 4:
            red = expand((value >> 12) & 0xF)
            green = expand((value >> 8) & 0xF)
            blue = expand((value >> 4) & 0xF)
            opacity = expand(value & 0xF)
        case 6:
            red = Double((value >> 16) & 0xFF) / 255
            green = Double((value >> 8) & 0xFF) / 255
            blue = Double(value & 0xFF) / 255
            opacity = 1
        case 8:
            red = Double((value >> 24) & 0xFF) / 255
            green = Double((value >> 16) & 0xFF) / 255
            blue = Double((value >> 8) & 0xFF) / 255
            opacity = Double(value & 0xFF) / 255
        default:
            return nil
        }

        self.init(red: red, green: green, blue: blue, opacity: opacity)
    }
}

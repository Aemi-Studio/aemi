/// How well text reads on a background.
public enum Contrast {
    /// WCAG 2's contrast ratio, 1 to 21: (lighter + 0.05) / (darker + 0.05) of the two relative luminances. Text needs
    /// 4.5 (large text 3) for level AA, 7 for AAA.
    public static func ratio(_ first: RGB, _ second: RGB) -> Double {
        ratio(luminance: first.relativeLuminance, second.relativeLuminance)
    }

    /// The same from two relative luminances, 0 to 1 (clamped).
    public static func ratio(luminance first: Double, _ second: Double) -> Double {
        let (a, b) = (clamped(first), clamped(second))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// APCA's lightness contrast, Lc (APCA-W3 0.0.98G-4g): about -108 to 106, positive for dark text on a light
    /// background, negative for light on dark, 0 when they are too close. Body text wants |Lc| of 75 or more, large text
    /// 60, other text 45. Its sign and its asymmetry are the point: it is not symmetric in text and background.
    public static func lightness(text: RGB, background: RGB) -> Double {
        let textY = softClamped(screenLuminance(text))
        let backgroundY = softClamped(screenLuminance(background))
        guard abs(backgroundY - textY) >= APCA.minimumDelta else { return 0 }
        if backgroundY > textY {
            let sapc = (power(backgroundY, APCA.normalBackground) - power(textY, APCA.normalText)) * APCA.scale
            return sapc < APCA.lowClip ? 0 : (sapc - APCA.lowOffset) * 100
        }
        let sapc = (power(backgroundY, APCA.reverseBackground) - power(textY, APCA.reverseText)) * APCA.scale
        return sapc > -APCA.lowClip ? 0 : (sapc + APCA.lowOffset) * 100
    }

    /// APCA's estimate of screen luminance: a simple 2.4 power on each component, its own weights.
    private static func screenLuminance(_ colour: RGB) -> Double {
        APCA.redWeight * power(colour.red, APCA.trc) + APCA.greenWeight * power(colour.green, APCA.trc)
            + APCA.blueWeight * power(colour.blue, APCA.trc)
    }

    /// Near black, lifted toward a threshold, as APCA models flare.
    private static func softClamped(_ luminance: Double) -> Double {
        luminance > APCA.blackThreshold
            ? luminance : luminance + power(APCA.blackThreshold - luminance, APCA.blackClamp)
    }

    private static func clamped(_ value: Double) -> Double {
        value.isNaN ? 0 : min(max(value, 0), 1)
    }

    /// APCA-W3 0.0.98G-4g's constants.
    private enum APCA {
        static let trc = 2.4
        static let redWeight = 0.212_672_9
        static let greenWeight = 0.715_152_2
        static let blueWeight = 0.072_175_0
        static let normalBackground = 0.56
        static let normalText = 0.57
        static let reverseText = 0.62
        static let reverseBackground = 0.65
        static let blackThreshold = 0.022
        static let blackClamp = 1.414
        static let scale = 1.14
        static let lowOffset = 0.027
        static let lowClip = 0.1
        static let minimumDelta = 0.000_5
    }
}

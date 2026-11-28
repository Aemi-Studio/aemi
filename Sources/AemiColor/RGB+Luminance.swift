extension RGB {
    /// One component from gamma-encoded to linear light, by the sRGB transfer function (IEC 61966-2-1).
    public static func linear(_ component: Double) -> Double {
        component <= 0.040_45 ? component / 12.92 : power((component + 0.055) / 1.055, 2.4)
    }

    /// One component from linear light to gamma-encoded, by the sRGB transfer function.
    public static func encoded(_ component: Double) -> Double {
        component <= 0.003_130_8 ? component * 12.92 : 1.055 * power(component, 1 / 2.4) - 0.055
    }

    /// Relative luminance as WCAG 2 defines it: Rec. 709 weights on linear components, 0 (black) to 1 (white).
    public var relativeLuminance: Double {
        0.2126 * Self.linear(red) + 0.7152 * Self.linear(green) + 0.0722 * Self.linear(blue)
    }

    /// Luma: Rec. 709 weights on the gamma-encoded components, 0 to 1. Core Animation's backdrop luma is this, taken in
    /// the display's colour space (AemiSDR's ADR-0010).
    public var luma: Double {
        0.2126 * red + 0.7152 * green + 0.0722 * blue
    }

    /// The relative luminance of the grey whose luma is `luma`: exact for greys, an estimate for colours. A luma read
    /// from the screen is turned so into what `Contrast.ratio(luminance:_:)` takes.
    public static func luminance(ofLuma luma: Double) -> Double {
        linear(min(max(luma.isNaN ? 0 : luma, 0), 1))
    }
}

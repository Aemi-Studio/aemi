/// A colour with an opacity, laid over what is under it.
public struct Layer: Sendable, Hashable {
    public let color: RGB
    /// 0 (nothing of it) to 1 (opaque); clamped.
    public let opacity: Double

    public init(_ color: RGB, opacity: Double = 1) {
        self.color = color
        self.opacity = opacity.isNaN ? 0 : min(max(opacity, 0), 1)
    }

    /// This layer over `below`, mixed on the gamma-encoded components, as Core Animation and browsers composite by
    /// default (not in linear light).
    public func over(_ below: RGB) -> RGB {
        RGB(
            red: color.red * opacity + below.red * (1 - opacity),
            green: color.green * opacity + below.green * (1 - opacity),
            blue: color.blue * opacity + below.blue * (1 - opacity)
        )
    }

    /// What shows through `layers`, listed from the bottom up, laid on `base`.
    public static func composite(_ layers: [Self], over base: RGB) -> RGB {
        layers.reduce(base) { below, layer in layer.over(below) }
    }
}

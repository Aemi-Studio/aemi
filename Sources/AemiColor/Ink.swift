/// Choosing the colour of text for what is under it.
public enum Ink {
    /// Of `candidates`, the first that reaches `minimum` contrast ratio with `background`; else the one with the most.
    /// Nil only when there are no candidates.
    public static func choose(
        from candidates: [RGB],
        on background: RGB,
        minimum: Double = 4.5
    ) -> RGB? {
        choose(from: candidates, onLuminance: background.relativeLuminance, minimum: minimum)
    }

    /// The same for a background known only by its relative luminance (a luma read from the screen, through
    /// `RGB.luminance(ofLuma:)`).
    public static func choose(
        from candidates: [RGB],
        onLuminance background: Double,
        minimum: Double = 4.5
    ) -> RGB? {
        let scored = candidates.map { ($0, Contrast.ratio(luminance: $0.relativeLuminance, background)) }
        return scored.first { $0.1 >= minimum }?.0 ?? scored.max { $0.1 < $1.1 }?.0
    }

    /// Whether dark text reads better than light text on a background of this relative luminance: the luminance where
    /// black and white have equal WCAG contrast is about 0.179 (a mid grey of #767676 reads alike in both).
    public static func prefersDark(onLuminance background: Double) -> Bool {
        Contrast.ratio(luminance: 0, background) >= Contrast.ratio(luminance: 1, background)
    }
}

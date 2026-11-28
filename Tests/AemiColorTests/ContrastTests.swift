import Testing

@testable import AemiColor

/// WCAG 2 and APCA against their published values, compositing, and choosing an ink.
struct ContrastTests {
    @Test func `WCAG ratios are the published ones`() throws {
        #expect(abs(Contrast.ratio(.black, .white) - 21) < 1e-9)
        #expect(abs(Contrast.ratio(.white, .white) - 1) < 1e-9)
        // #767676 on white is the darkest grey at 4.5:1 (4.54); #777777 just misses it (4.48).
        #expect(Contrast.ratio(try #require(RGB(hex: "#767676")), .white) >= 4.5)
        #expect(Contrast.ratio(try #require(RGB(hex: "#777777")), .white) < 4.5)
        #expect(abs(Contrast.ratio(try #require(RGB(hex: "#777")), .white) - 4.478) < 0.001)
    }

    /// APCA-W3 0.0.98G-4g's own test values (Myndex's "apca-w3" README).
    @Test(arguments: [
        ("#888888", "#ffffff", 63.056), ("#ffffff", "#888888", -68.541), ("#000000", "#aaaaaa", 58.146),
        ("#aaaaaa", "#000000", -56.24), ("#112233", "#ddeeff", 91.66), ("#ddeeff", "#112233", -93.07),
        ("#000000", "#ffffff", 106.04), ("#ffffff", "#000000", -107.88)
    ])
    func `APCA Lc is the published one`(text: String, background: String, expected: Double) throws {
        let value = Contrast.lightness(
            text: try #require(RGB(hex: text)),
            background: try #require(RGB(hex: background))
        )
        #expect(abs(value - expected) < 0.01, "\(text) on \(background): \(value)")
    }

    @Test func `too close is no contrast at all`() {
        #expect(Contrast.lightness(text: RGB(white: 0.5), background: RGB(white: 0.5)) == 0)
        #expect(Contrast.lightness(text: RGB(white: 0.52), background: RGB(white: 0.5)) == 0)
    }

    @Test func `the transfer function goes both ways and luma is taken on encoded values`() {
        for value in stride(from: 0.0, through: 1.0, by: 0.05) {
            #expect(abs(RGB.encoded(RGB.linear(value)) - value) < 1e-12)
        }
        #expect(abs(RGB(white: 0.5).luma - 0.5) < 1e-12)
        #expect(abs(RGB(red: 1, green: 0, blue: 0).luma - 0.2126) < 1e-12)
        #expect(abs(RGB.luminance(ofLuma: 0.5) - RGB(white: 0.5).relativeLuminance) < 1e-12)
        #expect(RGB.luminance(ofLuma: .nan) == 0 && RGB.luminance(ofLuma: 2) == 1)
    }

    @Test func `layers composite from the bottom up on encoded values`() {
        let half = Layer(.white, opacity: 0.5)
        #expect(half.over(.black) == RGB(white: 0.5))
        #expect(Layer.composite([Layer(.white), Layer(.black, opacity: 0.25)], over: .black) == RGB(white: 0.75))
        #expect(Layer.composite([], over: .white) == .white)
        #expect(Layer(.white, opacity: .nan).over(.black) == .black && Layer(.white, opacity: 4).opacity == 1)
    }

    @Test func `an ink is the first to reach the minimum, else the best`() throws {
        let inks = [RGB.white, RGB.black]
        #expect(Ink.choose(from: inks, on: .black) == .white)
        #expect(Ink.choose(from: inks, on: .white) == .black)
        let grey = try #require(RGB(hex: "#767676"))
        #expect(Ink.choose(from: [grey, .black], on: .white) == grey)
        #expect(Ink.choose(from: [RGB(white: 0.6)], on: .white, minimum: 21) == RGB(white: 0.6))
        #expect(Ink.choose(from: [], on: .white) == nil)
        #expect(Ink.prefersDark(onLuminance: 0.2) && !Ink.prefersDark(onLuminance: 0.15))
    }

    @Test func `parsing hex and bytes`() {
        #expect(RGB(hex: "fff") == .white && RGB(hex: "#000000") == .black)
        #expect(RGB(hex: "#12345") == nil && RGB(hex: "#gggggg") == nil && RGB(hex: "") == nil)
        #expect(RGB(bytes: [255, 255, 255]) == .white && RGB(bytes: [1, 2]) == nil)
        #expect(RGB(red: .nan, green: 2, blue: -1) == RGB(red: 0, green: 1, blue: 0))
    }
}

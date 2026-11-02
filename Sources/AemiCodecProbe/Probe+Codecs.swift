import AemiKernel

// Hex, percent-coding and byte search against references written here, on the host's SIMD tier.
extension Probe {
    mutating func runCodecs() {
        let digits = Array("0123456789abcdef".utf8)
        for count in 0 ... 300 {
            let input = bytes(count)
            let hex = Hex.encode(input)
            expect(hex == input.flatMap { [digits[Int($0 >> 4)], digits[Int($0 & 15)]] }, "hex encode \(count)")
            expect((try? Hex.decode(hex)) == input, "hex round trip \(count)")
            if !hex.isEmpty {
                var broken = hex
                let at = Int(next() % UInt64(hex.count))
                broken[at] = UInt8(ascii: "g")
                expect(
                    (try? Hex.decode(broken)) == nil
                        && Self.hexError(broken) == .invalidByte(UInt8(ascii: "g"), offset: at),
                    "hex error \(count)"
                )
            }
            let percent = PercentCoding.encode(input)
            expect(percent == Self.naivePercent(input), "percent encode \(count)")
            expect(PercentCoding.decode(percent) == input, "percent round trip \(count)")
            let letters = (0 ..< count).map { _ in UInt8(ascii: "a") + UInt8(next() % 3) }
            let needle = Array(letters.suffix(Int(next() % 9)))
            expect(
                ByteSearch.firstRange(of: needle, in: letters[...]) == Self.naiveFind(needle, letters),
                "search \(count)"
            )
        }
        var hay = [UInt8](repeating: UInt8(ascii: "a"), count: 300_000)
        var needle = [UInt8](repeating: UInt8(ascii: "a"), count: 5_001)
        needle[2_500] = UInt8(ascii: "b")
        expect(ByteSearch.firstRange(of: needle, in: hay[...]) == nil, "adversarial search")
        hay.replaceSubrange((hay.count - needle.count)..., with: needle)
        expect(
            ByteSearch.firstRange(of: needle, in: hay[...]) == (hay.count - needle.count) ..< hay.count,
            "adversarial match"
        )
    }

    static func hexError(_ text: [UInt8]) -> Hex.DecodeError? {
        do {
            _ = try Hex.decode(text)
            return nil
        } catch {
            return error
        }
    }

    static func naivePercent(_ input: [UInt8]) -> [UInt8] {
        let digits = Array("0123456789ABCDEF".utf8)
        return input.flatMap {
            PercentCoding.isUnreserved($0) ? [$0] : [UInt8(ascii: "%"), digits[Int($0 >> 4)], digits[Int($0 & 15)]]
        }
    }

    static func naiveFind(_ needle: [UInt8], _ hay: [UInt8]) -> Range<Int>? {
        guard !needle.isEmpty, hay.count >= needle.count else { return nil }
        for start in 0 ... hay.count - needle.count where Array(hay[start ..< start + needle.count]) == needle {
            return start ..< start + needle.count
        }
        return nil
    }
}

import AemiKernel
import AemiTestKit
import Testing

/// PercentCoding's SIMD paths against a naive reference written here: random and adversarial inputs of every length around the
/// 16-byte blocks, custom `allowed` sets (ones the kernels can hold and ones they cannot), forms, and malformed escapes.
struct PercentCodingKernelTests {
    private static func naiveEncode(_ bytes: [UInt8], allowed: (UInt8) -> Bool) -> [UInt8] {
        let digits = Array("0123456789ABCDEF".utf8)
        return bytes.flatMap { allowed($0) ? [$0] : [UInt8(ascii: "%"), digits[Int($0 >> 4)], digits[Int($0 & 15)]] }
    }

    private static func naiveDecode(_ bytes: [UInt8], plus: Bool) -> [UInt8]? {
        var out: [UInt8] = []
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "%") {
                guard index + 2 < bytes.count, let high = Hex.value(bytes[index + 1]),
                    let low = Hex.value(bytes[index + 2])
                else {
                    return nil
                }
                out.append(high << 4 | low)
                index += 3
            } else {
                out.append(plus && byte == UInt8(ascii: "+") ? UInt8(ascii: " ") : byte)
                index += 1
            }
        }
        return out
    }

    @Test func encodeAndDecodeMatchTheReferenceForEveryLengthAndDensity() {
        var rng = SeededRNG(seed: Seed.named("percent.kernels"))
        let plain = Array("abcdefghijklmnopqrstuvwxyz0123456789-._~".utf8)
        for length in 0 ... 300 {
            for density in 0 ..< 4 {
                let bytes: [UInt8] = (0 ..< length)
                    .map { _ in
                        switch density {
                            case 0: UInt8(truncatingIfNeeded: rng.next())
                            case 1:
                                rng.next() % 9 == 0 ? UInt8(ascii: "/") : plain[Int(rng.next() % UInt64(plain.count))]
                            case 2: plain[Int(rng.next() % UInt64(plain.count))]
                            default: rng.next() % 2 == 0 ? UInt8(ascii: " ") : UInt8(ascii: "%")
                        }
                    }
                let encoded = PercentCoding.encode(bytes)
                #expect(encoded == Self.naiveEncode(bytes, allowed: PercentCoding.isUnreserved), "length \(length)")
                #expect(PercentCoding.encode(NonContiguousBytes(storage: bytes)) == encoded)
                #expect(PercentCoding.decode(encoded) == bytes)
                #expect(PercentCoding.decode(NonContiguousBytes(storage: encoded)) == bytes)
                // Arbitrary text decoded as is and as a form: the same answer as the reference, `nil` included.
                for plus in [false, true] {
                    let decoded = plus ? PercentCoding.decodeForm(bytes) : PercentCoding.decode(bytes)
                    #expect(decoded == Self.naiveDecode(bytes, plus: plus), "length \(length) density \(density)")
                }
            }
        }
    }

    @Test func customSetsAreHonouredWhetherOrNotTheKernelsCanHoldThem() {
        var rng = SeededRNG(seed: Seed.named("percent.custom"))
        let bytes = (0 ..< 1_000).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
        let predicates: [(UInt8) -> Bool] = [
            { _ in true }, { _ in false }, { $0 != UInt8(ascii: "/") }, { $0 < 0x80 && $0 != 0x20 },
            { $0 % 3 != 0 },  // a set no nibble tables hold: the byte loop
            { PercentCoding.isUnreserved($0) || $0 == UInt8(ascii: "/") }
        ]
        for allowed in predicates {
            #expect(PercentCoding.encode(bytes, allowed: allowed) == Self.naiveEncode(bytes, allowed: allowed))
            #expect(
                PercentCoding.encode(bytes[..<40], allowed: allowed)
                    == Self.naiveEncode(Array(bytes[..<40]), allowed: allowed)
            )
        }
    }

    @Test func malformedEscapesAnywhereAreRejected() {
        let text = Array(String(repeating: "abc%41def", count: 12).utf8)
        for position in 0 ..< text.count {
            for junk in [UInt8(ascii: "%"), UInt8(ascii: "G"), UInt8(ascii: "+")] {
                var broken = text
                broken[position] = junk
                #expect(PercentCoding.decode(broken) == Self.naiveDecode(broken, plus: false), "position \(position)")
                #expect(
                    PercentCoding.decodeForm(broken) == Self.naiveDecode(broken, plus: true),
                    "position \(position)"
                )
            }
        }
        #expect(PercentCoding.decode(Array((String(repeating: "a", count: 40) + "%4").utf8)) == nil)
    }

    @Test func largeInputsRoundTrip() {
        var rng = SeededRNG(seed: Seed.named("percent.large"))
        let bytes = (0 ..< (1 << 20)).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
        #expect(PercentCoding.decode(PercentCoding.encode(bytes)) == bytes)
    }
}

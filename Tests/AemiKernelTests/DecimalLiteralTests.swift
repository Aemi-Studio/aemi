import AemiKernel
import AemiTestKit
import Testing

/// `DecimalScanner` and `DecimalFloat.double(_:in:)` (ADR 0031) against the standard library: every value the scanner reads rounds
/// to the `Double` that `Double(String)` gives for the same digits, and every integer it reads is `Int64(String)`'s, over seeded
/// literals that exercise the SWAR eight-digit step, padded zeros, the nineteen-digit edge, the 768-digit slow path and separators.
struct DecimalLiteralTests {
    static func literal(_ generator: inout SeededRNG) -> String {
        func digits(_ count: Int) -> String {
            String((0 ..< count).map { _ in generator.int(5) == 0 ? "0" : Character(String(generator.int(10))) })
        }
        var text = ["", "-", "+"][generator.int(3)]
        let shape = generator.int(6)
        let integer = shape == 0 ? 1 : [1, 2, 7, 8, 9, 16, 19, 20, 25, 40][generator.int(10)]
        text += generator.int(4) == 0 ? "0" : String(generator.int(9) + 1) + digits(integer - 1)
        if shape >= 2 {
            text += "." + (generator.int(3) == 0 ? String(repeating: "0", count: generator.int(30)) : "")
            text += digits([1, 3, 8, 9, 17, 18, 19, 20, 30][generator.int(9)])
        }
        if shape >= 4 {
            text +=
                ["e", "E", "e+", "e-", "E-"][generator.int(5)]
                + String(generator.int([3, 30, 330, 400][generator.int(4)]))
        }
        return text
    }

    @Test func `every literal rounds as Double(String) does, and integers read as Int64(String)`() throws {
        var generator = SeededRNG(seed: 0xDEC1_3A11)
        for _ in 0 ..< 40_000 {
            let text = Self.literal(&generator)
            let bytes = Array(text.utf8)
            let literal = try #require(DecimalScanner.scan(bytes, from: 0), "\(text)")
            #expect(literal.end == bytes.count, "\(text)")
            let value = DecimalFloat.double(literal, in: bytes)
            #expect(
                bytes.withUnsafeBufferPointer { DecimalFloat.double(literal, in: $0) }.bitPattern == value.bitPattern
            )
            let expected = try #require(Double(text))
            #expect(
                value.bitPattern == expected.bitPattern || (value == 0 && expected == 0),
                "\(text): \(value) \(expected)"
            )
            if literal.isInteger { #expect(literal.integerValue == Int64(text), "\(text)") }
            let single = DecimalFloat.float(literal, in: bytes)
            let wanted = try #require(Float(text))
            #expect(single.bitPattern == wanted.bitPattern || (single == 0 && wanted == 0), "\(text)")
        }
    }

    @Test func `past 768 significant digits the sticky digit still rounds right`() throws {
        // 2^-1074 / 2 is a tie between 0 and the smallest subnormal; one nonzero digit far past it decides upward.
        let half =
            "2.4703282292062327208828439643411068618252990130716238221279284125033775363510437593264991818081799618989828234772285886546332835517796989819938739800539093906315035659515570226392290858392449105184435931802849936536152500319370457678249219365623669863658480757001585769269903706311928279558551332927834338409351978015531246597263579574622766465272827220056374006485499977096599470454020828166226237857393450736339007967761930577506740176324673600968951340535537458516661134223766678604162159680461914467291840300530057530849048765391711386591646239524912623653881879636239373280423891018672348497668235089863388587925628302755995657524455507255189313690836254779186948667994968324049705821028513185451396213837722826145437693412532098591327667236328125"
        func value(_ text: String) throws -> Double {
            let bytes = Array(text.utf8)
            return DecimalFloat.double(try #require(DecimalScanner.scan(bytes, from: 0)), in: bytes)
        }
        // The exact tie rounds to even (zero); a nonzero digit 790 places in rounds up to the smallest subnormal.
        #expect(try value(half + "e-324") == 0)
        #expect(try value(half + "0000000000000000000000000000001e-324") == Double.leastNonzeroMagnitude)
        #expect(try value("-" + half + "1e-324") == -Double.leastNonzeroMagnitude)
    }

    @Test func `generated literals with separators anywhere between digits round as their plain text does`() throws {
        var generator = SeededRNG(seed: 0x5E9A)
        for _ in 0 ..< 20_000 {
            let plain = Self.literal(&generator)
            var text = ""
            var previousWasDigit = false
            for character in plain {
                let isDigit = character.isASCII && character.isNumber
                if isDigit, previousWasDigit, generator.int(4) == 0 { text += "_" }
                text.append(character)
                previousWasDigit = isDigit
            }
            let bytes = Array(text.utf8)
            let literal = try #require(DecimalScanner.scan(bytes, from: 0, separator: 0x5F), "\(text)")
            #expect(literal.end == bytes.count, "\(text)")
            let expected = try #require(Double(plain))
            let value = DecimalFloat.double(literal, in: bytes, separator: 0x5F)
            #expect(value.bitPattern == expected.bitPattern || (value == 0 && expected == 0), "\(text)")
            if literal.isInteger { #expect(literal.integerValue == Int64(plain), "\(text)") }
        }
    }

    @Test func `zeros that only pad keep the fast paths, for Double and Float`() throws {
        for text in ["1.0000000000000000000000", "0.000000000000000000001", "-0.00000000000000000000000012345"] {
            let literal = try #require(DecimalScanner.scan(Array(text.utf8), from: 0))
            #expect(DecimalFloat.fastDouble(literal) == Double(text), "\(text)")
        }
        for text in ["1.00000000000", "12300000000", "1.25000000000"] {
            let small = try #require(DecimalScanner.scan(Array(text.utf8), from: 0)).trimmed
            #expect(small.significand <= 1 << 24, "\(text)")
            #expect(
                DecimalFloat.float(significand: UInt32(small.significand), exponent: small.exponent, negative: false)
                    == Float(text),
                "\(text)"
            )
        }
    }

    @Test func `separators are read between digits only, and the value ignores them`() throws {
        for (text, plain) in [
            ("1_000", "1000"), ("3.141_592_6", "3.1415926"), ("6.02e2_3", "6.02e23"), ("1_2_3_4_5_6_7_8_9", "123456789")
        ] {
            let bytes = Array(text.utf8)
            let literal = try #require(DecimalScanner.scan(bytes, from: 0, separator: 0x5F))
            #expect(literal.end == bytes.count)
            #expect(DecimalFloat.double(literal, in: bytes, separator: 0x5F) == Double(plain))
        }
        for (text, end) in [("1__0", 1), ("1_", 1), ("_1", -1), ("1._5", 1), ("1e_5", 1), ("1_000", 1)] {
            let literal = DecimalScanner.scan(Array(text.utf8), from: 0, separator: text == "1_000" ? nil : 0x5F)
            #expect(literal?.end ?? -1 == end, "\(text)")
        }
    }

    @Test func `the grammar facts: leading zeros, a point or e without digits, signs, digit counts`() throws {
        let cases: [(String, Int, Bool, Int, Int, Bool)] = [
            // text, end, leading zero, integer digits, fraction digits, has exponent
            ("0", 1, false, 1, 0, false), ("00", 2, true, 2, 0, false), ("012.5", 5, true, 3, 1, false),
            ("1.", 1, false, 1, 0, false), ("1.e5", 1, false, 1, 0, false), ("1e", 1, false, 1, 0, false),
            ("1e+", 1, false, 1, 0, false), ("-0.0e-0", 7, false, 1, 1, true),
            ("12345678901234567890.5", 22, false, 20, 1, false)
        ]
        for (text, end, leadingZero, integerDigits, fractionDigits, hasExponent) in cases {
            let literal = try #require(DecimalScanner.scan(Array(text.utf8), from: 0), "\(text)")
            #expect(literal.end == end, "\(text)")
            #expect(literal.leadingZero == leadingZero, "\(text)")
            #expect(literal.integerDigits == integerDigits, "\(text)")
            #expect(literal.fractionDigits == fractionDigits, "\(text)")
            #expect(literal.hasExponent == hasExponent, "\(text)")
        }
        for text in ["", "-", "+", ".5", "e5", "x"] {
            #expect(DecimalScanner.scan(Array(text.utf8), from: 0) == nil, "\(text)")
        }
        #expect(DecimalScanner.scan(Array("ab12".utf8), from: 2)?.integerValue == 12)
        #expect(DecimalScanner.scan(Array("-9223372036854775808".utf8), from: 0)?.integerValue == .min)
        #expect(DecimalScanner.scan(Array("9223372036854775808".utf8), from: 0)?.integerValue == nil)
        #expect(DecimalScanner.scan(Array("100000000000000000000".utf8), from: 0)?.integerValue == nil)
    }
}

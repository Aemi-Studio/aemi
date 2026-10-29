import AemiKernel
import AemiTestKit
import Testing

/// `UTF8Scalar`, promoted from AemiRegex (aemi ADR 0017): a sequence is a scalar only when it is well formed. The reference is the
/// standard library's own strict decoder.
struct UTF8ScalarTests {
    /// The standard library's reading of the scalar at the start of `bytes`: its value and width, or nil when the bytes there are not
    /// a well-formed scalar.
    private static func reference(_ bytes: [UInt8]) -> (value: UInt32, width: Int)? {
        var iterator = bytes.makeIterator()
        var decoder = Unicode.UTF8()
        guard case .scalarValue(let scalar) = decoder.decode(&iterator) else { return nil }
        return (scalar.value, String(scalar).utf8.count)
    }

    private static func check(_ bytes: [UInt8], _ label: @autoclosure () -> String) {
        let expected = reference(bytes)
        let actual = UTF8Scalar.scalar(bytes, at: 0)
        #expect(actual?.value == expected?.value && actual?.width == expected?.width, "\(label())")
        #expect(UTF8Scalar.width(bytes, at: 0) == (expected?.width ?? 1), "\(label()) width")
        #expect(UTF8Scalar.step(bytes, at: 0) == (expected?.width ?? 1), "\(label()) step")
    }

    @Test func `every one- and two-byte sequence reads as the standard library reads it`() {
        for a in 0 ... 255 {
            Self.check([UInt8(a)], "\(a)")
            for b in 0 ... 255 { Self.check([UInt8(a), UInt8(b)], "\(a) \(b)") }
        }
    }

    @Test func `three- and four-byte sequences read as the standard library reads them`() {
        var rng = SeededRNG(seed: 0x75_7466_38)
        // Lead bytes from every class, continuation bytes biased to the edges where the rules bite.
        let leads: [UInt8] = [0xE0, 0xE1, 0xEC, 0xED, 0xEE, 0xEF, 0xF0, 0xF1, 0xF3, 0xF4, 0xF5, 0xC0, 0xC1, 0x80]
        let tails: [UInt8] = [0x7F, 0x80, 0x8F, 0x90, 0x9F, 0xA0, 0xBF, 0xC0, 0x41]
        for lead in leads {
            for _ in 0 ..< 400 {
                let bytes = [lead] + (0 ..< 3).map { _ in tails.randomElement(using: &rng) ?? 0x80 }
                Self.check(bytes, "\(bytes)")
                Self.check(Array(bytes.prefix(3)), "\(bytes.prefix(3))")
            }
        }
    }

    @Test func `overlong forms, surrogates and values past U+10FFFF are not scalars`() {
        for bytes: [UInt8] in [
            [0xC0, 0x80], [0xE0, 0x80, 0x80], [0xF0, 0x80, 0x80, 0x80], [0xED, 0xA0, 0x80], [0xF4, 0x90, 0x80, 0x80],
            [0x80], [0xE2, 0x82]
        ] {
            #expect(UTF8Scalar.scalar(bytes, at: 0) == nil, "\(bytes)")
        }
        #expect(UTF8Scalar.scalar([0xF0, 0x9F, 0x98, 0x80], at: 0)! == (0x1F600, 4))
    }

    @Test func `a scalar is read backward from its end, and only a whole one is`() {
        let text = Array("aé日😀".utf8)
        var ends: [Int] = []
        var index = 0
        while index < text.count {
            index += UTF8Scalar.step(text, at: index)
            ends.append(index)
        }
        for (end, expected) in zip(ends, "aé日😀".unicodeScalars) {
            #expect(UTF8Scalar.scalar(text, before: end)?.value == expected.value, "before \(end)")
        }
        #expect(UTF8Scalar.scalar(text, before: 0) == nil)
        #expect(UTF8Scalar.scalar(text, before: 2) == nil, "inside é")
        #expect(UTF8Scalar.scalar([0x61, 0x80], before: 2) == nil, "a lone continuation byte")
    }

    @Test func `a read at the end is nil`() {
        #expect(UTF8Scalar.scalar([0x61], at: 1) == nil)
        #expect(UTF8Scalar.scalar([UInt8](), at: 0) == nil)
    }
}

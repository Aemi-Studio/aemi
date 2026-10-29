import AemiKernel
import AemiTestKit
import Testing

/// `UTF8RangeSequences`, promoted from AemiRegex (aemi ADR 0018): the sequences of a range match exactly the UTF-8 encodings of its
/// members. The reference encoder is the standard library's.
struct UTF8RangeSequencesTests {
    private static func matches(_ sequences: [[ClosedRange<UInt8>]], _ bytes: [UInt8]) -> Int {
        sequences.filter { sequence in
            sequence.count == bytes.count && zip(sequence, bytes).allSatisfy { $0.contains($1) }
        }
        .count
    }

    private static func encoding(_ value: UInt32) -> [UInt8]? {
        Unicode.Scalar(value).map { Array(String($0).utf8) }
    }

    private static func check(_ range: ClosedRange<UInt32>) {
        let sequences = UTF8RangeSequences.sequences(range)
        // Each member, and the neighbours just outside, which must not match.
        let probes = Array(range).count <= 5000 ? Array(range) : Array(range.prefix(2500)) + Array(range.suffix(2500))
        for value in probes {
            guard let bytes = encoding(value) else { continue }
            #expect(Self.matches(sequences, bytes) == 1, "U+\(String(value, radix: 16)) in \(range)")
            #expect(UTF8RangeSequences.encode(value) == bytes)
        }
        for value in [range.lowerBound &- 1, range.upperBound &+ 1] where value <= 0x10FFFF {
            guard let bytes = encoding(value) else { continue }
            #expect(Self.matches(sequences, bytes) == 0, "U+\(String(value, radix: 16)) outside \(range)")
        }
    }

    @Test func `the boundaries of every encoding length and of the surrogates are split exactly`() {
        for range: ClosedRange<UInt32> in [
            0 ... 0x7F, 0x7F ... 0x80, 0x7FF ... 0x800, 0xFFFF ... 0x10000, 0xD7FF ... 0xE000, 0x80 ... 0x10FFFF,
            0 ... 0x10FFFF,
            0x10FFFE ... 0x10FFFF, 0x3B1 ... 0x3C9, 0x4E00 ... 0x9FFF
        ] {
            Self.check(range)
        }
    }

    @Test func `random ranges match exactly their members`() {
        var rng = SeededRNG(seed: 0x7365_7173)
        for _ in 0 ..< 300 {
            let a = UInt32(rng.next(upTo: 0x110000))
            let b = min(0x10FFFF, a + UInt32(rng.next(upTo: [16, 300, 5000][rng.next(upTo: 3)])))
            Self.check(a ... b)
        }
    }

    @Test func `a range of surrogates only has no sequence`() {
        #expect(UTF8RangeSequences.sequences(0xD800 ... 0xDFFF).isEmpty)
    }
}

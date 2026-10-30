import AemiKernels
import AemiTestKit
import Testing

/// Every kernel with its input flush against an inaccessible page, at the end and at the start (aemi ADR 0021): a read past
/// either edge crashes the run, which no comparison of results would show. The filler matches no needle, so each scan runs to
/// the end; a second pass puts a hit in the last byte. Lengths cover every 16- and 64-byte tail and the 4 KiB CRC chunk.
struct AemiKernelsGuardPageTests {
    static let lengths = Array(0 ... 130) + [255, 256, 257, 1023, 4095, 4096, 4097, 8269]

    /// `body` for every length and edge, with `count` filler bytes (`a`), optionally the last one replaced by `last`.
    static func each(last: UInt8? = nil, _ body: (UnsafeMutablePointer<UInt8>, Int) -> Void) {
        for edge in GuardedBytes.Edge.allCases {
            for count in lengths {
                var bytes = [UInt8](repeating: UInt8(ascii: "a"), count: count)
                if let last, count > 0 { bytes[count - 1] = last }
                GuardedBytes.with(bytes, against: edge) { body($0, count) }
            }
        }
    }

    @Test func `checksums, bit counts and UTF-16 narrowing stay inside the input`() {
        Self.each { base, count in
            #expect(
                AemiKernels.crc32c(7, base, count: count) == AemiKernels.crc32c(7, base, count: count, backend: .scalar)
            )
            #expect(
                AemiKernels.bitCount(base, count: count) == AemiKernels.bitCount(base, count: count, backend: .scalar))
            GuardedBytes.with([UInt8](repeating: 0, count: count / 2)) { ascii in
                #expect(
                    AemiKernels.asciiPrefix(utf16LE: base, units: count / 2, into: ascii)
                        == AemiKernels.asciiPrefix(utf16LE: base, units: count / 2, into: ascii, backend: .scalar))
            }
        }
    }

    @Test func `byte scans stay inside the input`() {
        for last: UInt8? in [nil, UInt8(ascii: "\"")] {
            Self.each(last: last) { base, count in
                let quote = UInt8(ascii: "\"")
                let escape = UInt8(ascii: "\\")
                #expect(
                    AemiKernels.firstIndexOfByte(base: base, count: count, needle: quote)
                        == AemiKernels.firstIndexOfByte(base: base, count: count, needle: quote, backend: .scalar))
                #expect(
                    AemiKernels.firstIndexOfAny(base: base, count: count, quote, escape, 1, 2, 3)
                        == AemiKernels.firstIndexOfAny(
                            base: base, count: count, quote, escape, 1, 2, 3, backend: .scalar))
                #expect(
                    AemiKernels.indexOfStringStop(base: base, count: count, quote: quote, escape: escape)
                        == AemiKernels.indexOfStringStop(
                            base: base, count: count, quote: quote, escape: escape, backend: .scalar))
                #expect(
                    AemiKernels.indexOfControlOrAny(base: base, count: count, quote, escape, 1, 2, 3)
                        == AemiKernels.indexOfControlOrAny(
                            base: base, count: count, quote, escape, 1, 2, 3, backend: .scalar))
                #expect(
                    AemiKernels.firstDisallowedText(base: base, count: count, minAllowed: 0x20, allowTab: true)
                        == AemiKernels.firstDisallowedText(
                            base: base, count: count, minAllowed: 0x20, allowTab: true, backend: .scalar))
                #expect(
                    AemiKernels.firstInvalidUTF8(base: base, count: count)
                        == AemiKernels.firstInvalidUTF8(base: base, count: count, backend: .scalar))
                #expect(
                    AemiKernels.firstNonASCII(base: base, count: count)
                        == AemiKernels.firstNonASCII(base: base, count: count, backend: .scalar))
                if let set = AemiKernels.ByteSet([quote, escape, 0x7B]) {
                    #expect(
                        AemiKernels.firstIndex(inSet: set, base: base, count: count)
                            == AemiKernels.firstIndex(inSet: set, base: base, count: count, backend: .scalar))
                }
                let buffer = UnsafeBufferPointer(start: base, count: count)
                #expect(
                    AemiKernels.firstIndex(ofPair: UInt8(ascii: "a"), quote, in: buffer, from: 0)
                        == (last == nil || count < 2 ? nil : count - 2))
                let pairs = AemiKernels.PairSet([(first: UInt8(ascii: "a"), second: quote)])
                #expect(
                    pairs.firstCandidate(in: buffer, from: 0)
                        == pairs.firstCandidate(in: buffer, from: 0, backend: .scalar))
                if let small = AemiKernels.SmallByteSet([quote, escape]) {
                    #expect(small.firstIndex(in: buffer, from: 0) == (last == nil || count == 0 ? nil : count - 1))
                }
            }
        }
    }

    @Test func `case folding stays inside both buffers`() {
        Self.each(last: UInt8(ascii: "Z")) { source, count in
            GuardedBytes.with([UInt8](repeating: 0, count: count)) { target in
                AemiKernels.foldASCII(into: target, from: source, count: count)
                #expect(count == 0 || target[count - 1] == UInt8(ascii: "z"))
            }
        }
    }

    @Test func `Hamming distances stay inside both vectors`() {
        Self.each { a, count in
            GuardedBytes.with([UInt8](repeating: 0xFF, count: count)) { b in
                #expect(
                    AemiKernels.hammingDistance(a, b, count: count)
                        == AemiKernels.hammingDistance(a, b, count: count, backend: .scalar))
            }
            guard count > 0 else { return }
            GuardedBytes.with([UInt8](repeating: 0, count: 2 * count)) { corpus in
                var out = [UInt32](repeating: 0, count: 2)
                out.withUnsafeMutableBufferPointer {
                    AemiKernels.hammingScan(query: a, corpus: corpus, width: count, count: 2, into: $0.baseAddress!)
                }
                #expect(out == [UInt32](repeating: UInt32(AemiKernels.bitCount(a, count: count)), count: 2))
            }
        }
    }
}

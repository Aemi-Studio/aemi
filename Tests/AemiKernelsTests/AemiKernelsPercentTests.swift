import AemiKernels
import AemiTestKit
import Testing

/// The percent-coding facade with its buffers flush against inaccessible pages (aemi ADR 0021), and the calls that break its
/// contract, which trap.
struct AemiKernelsPercentTests {
    static let lengths = Array(0 ... 100) + [255, 256, 257, 4095, 4096, 4097]
    static let reserved = AemiKernels.ByteSet((0 ... 255).map { UInt8($0) }.filter { !Self.unreserved($0) })!

    static func unreserved(_ b: UInt8) -> Bool {
        (b >= 0x30 && b <= 0x39) || (b | 0x20 >= 0x61 && b | 0x20 <= 0x7A) || b == 0x2D || b == 0x2E || b == 0x5F
            || b == 0x7E
    }

    @Test func `encoding and decoding stay inside buffers that end at a guard page`() {
        for edge in GuardedBytes.Edge.allCases {
            for count in Self.lengths {
                for pattern in 0 ..< 3 {
                    let bytes = (0 ..< count)
                        .map { i -> UInt8 in
                            pattern == 0
                                ? UInt8(ascii: "a")
                                : pattern == 1 ? (i % 7 == 6 ? 0x20 : 0x62) : UInt8(truncatingIfNeeded: i &* 37)
                        }
                    GuardedBytes.with(bytes, against: edge) { input in
                        let source = UnsafeBufferPointer(start: input, count: count)
                        let total = count + 2 * AemiKernels.count(inSet: Self.reserved, in: source)
                        GuardedBytes.with([UInt8](repeating: 0, count: total), against: edge) { encoded in
                            AemiKernels.percentEncode(
                                source,
                                escaping: Self.reserved,
                                into: UnsafeMutableBufferPointer(start: encoded, count: total)
                            )
                            GuardedBytes.with([UInt8](repeating: 0, count: total), against: edge) { decoded in
                                let written = AemiKernels.percentDecode(
                                    UnsafeBufferPointer(start: encoded, count: total),
                                    into: UnsafeMutableBufferPointer(start: decoded, count: total),
                                    plusAsSpace: false
                                )
                                #expect(written == count)
                                #expect((0 ..< count).allSatisfy { decoded[$0] == bytes[$0] }, "length \(count)")
                            }
                        }
                    }
                }
            }
        }
    }

    @Test func `an encode output of the wrong size, or a short decode output, traps`() async {
        await #expect(processExitsWith: .failure) {
            let input = [UInt8](repeating: 0x20, count: 40)
            var out = [UInt8](repeating: 0, count: 119)
            input.withUnsafeBufferPointer { i in
                out.withUnsafeMutableBufferPointer {
                    AemiKernels.percentEncode(i, escaping: AemiKernelsPercentTests.reserved, into: $0)
                }
            }
        }
        await #expect(processExitsWith: .failure) {
            let input = [UInt8](repeating: 0x61, count: 40)
            var out = [UInt8](repeating: 0, count: 39)
            _ = input.withUnsafeBufferPointer { i in
                out.withUnsafeMutableBufferPointer { AemiKernels.percentDecode(i, into: $0, plusAsSpace: false) }
            }
        }
    }
}

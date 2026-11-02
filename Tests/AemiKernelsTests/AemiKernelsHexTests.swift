import AemiKernels
import AemiTestKit
import Testing

/// The hex kernels' facade (`package` API) with input and output flush against inaccessible pages (aemi ADR 0021), against the
/// scalar reference, and the calls that break its contract, which trap.
struct AemiKernelsHexTests {
    static let lengths = Array(0 ... 140) + [255, 256, 257, 1023, 4095, 4096, 4097]

    @Test func `encoding and decoding stay inside buffers that end at a guard page`() {
        for edge in GuardedBytes.Edge.allCases {
            for count in Self.lengths {
                let bytes = (0 ..< count).map { UInt8(truncatingIfNeeded: $0 &* 29 &+ 3) }
                GuardedBytes.with(bytes, against: edge) { input in
                    GuardedBytes.with([UInt8](repeating: 0, count: 2 * count), against: edge) { digits in
                        AemiKernels.hexEncode(
                            input: UnsafeBufferPointer(start: input, count: count),
                            output: UnsafeMutableBufferPointer(start: digits, count: 2 * count),
                            uppercase: count % 2 == 0
                        )
                        var reference = [UInt8](repeating: 0, count: 2 * count)
                        reference.withUnsafeMutableBufferPointer {
                            AemiKernels.hexEncode(
                                input: UnsafeBufferPointer(start: input, count: count),
                                output: $0,
                                uppercase: count % 2 == 0,
                                backend: .scalar
                            )
                        }
                        #expect((0 ..< 2 * count).allSatisfy { digits[$0] == reference[$0] }, "length \(count)")
                        // Decode them back (and with a bad last digit), the output exactly `count` bytes.
                        for damage in [false, true] {
                            if damage, count > 0 { digits[2 * count - 1] = UInt8(ascii: "g") }
                            GuardedBytes.with([UInt8](repeating: 0, count: count), against: edge) { out in
                                let consumed = AemiKernels.hexDecode(
                                    input: UnsafeBufferPointer(start: digits, count: 2 * count),
                                    output: UnsafeMutableBufferPointer(start: out, count: count)
                                )
                                #expect(consumed == (damage && count > 0 ? 2 * count - 2 : 2 * count))
                                #expect((0 ..< consumed / 2).allSatisfy { out[$0] == bytes[$0] })
                            }
                        }
                    }
                }
            }
        }
    }

    @Test func `an output too small, or overlapping the input, traps`() async {
        await #expect(processExitsWith: .failure) {
            let input = [UInt8](repeating: 1, count: 32)
            var out = [UInt8](repeating: 0, count: 63)
            input.withUnsafeBufferPointer { i in
                out.withUnsafeMutableBufferPointer { AemiKernels.hexEncode(input: i, output: $0, uppercase: false) }
            }
        }
        await #expect(processExitsWith: .failure) {
            let input = [UInt8](repeating: 0x61, count: 64)
            var out = [UInt8](repeating: 0, count: 31)
            _ = input.withUnsafeBufferPointer { i in
                out.withUnsafeMutableBufferPointer { AemiKernels.hexDecode(input: i, output: $0) }
            }
        }
        await #expect(processExitsWith: .failure) {
            var buffer = [UInt8](repeating: 0x61, count: 96)
            buffer.withUnsafeMutableBufferPointer { b in
                AemiKernels.hexEncode(
                    input: UnsafeBufferPointer(rebasing: b[0 ..< 32]),
                    output: UnsafeMutableBufferPointer(rebasing: b[16 ..< 96]),
                    uppercase: false
                )
            }
        }
    }
}

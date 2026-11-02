import AemiKernels
import Testing

/// Sizes no real buffer has, handed to the codec facades: each must trap on its own check, before the kernel reads or writes
/// anything (the pointers here are valid for one byte only, so a kernel that ran would read far outside them).
struct AemiKernelsAbuseTests {
    @Test func `a hex input whose encoded length overflows Int traps before the kernel runs`() async {
        await #expect(processExitsWith: .failure) {
            var byte: UInt8 = 0
            var out: UInt8 = 0
            withUnsafeMutablePointer(to: &byte) { input in
                withUnsafeMutablePointer(to: &out) { output in
                    AemiKernels.hexEncode(
                        input: UnsafeBufferPointer(start: input, count: Int.max / 2 + 1),
                        output: UnsafeMutableBufferPointer(start: output, count: 1),
                        uppercase: false
                    )
                }
            }
        }
    }

    @Test func `a Base64 input far larger than its output traps before the kernel runs`() async {
        await #expect(processExitsWith: .failure) {
            var byte: UInt8 = 0x41
            var out: UInt8 = 0
            let table = [UInt8](repeating: 0x41, count: 64)
            table.withUnsafeBufferPointer { symbols in
                withUnsafeMutablePointer(to: &byte) { input in
                    withUnsafeMutablePointer(to: &out) { output in
                        _ = AemiKernels.base64EncodeBlocks(
                            table: symbols,
                            tail: 0,
                            input: UnsafeBufferPointer(start: input, count: 1 << 40),
                            output: UnsafeMutableBufferPointer(start: output, count: 1)
                        )
                    }
                }
            }
        }
        await #expect(processExitsWith: .failure) {
            var byte: UInt8 = 0x41
            var out: UInt8 = 0
            let lookup = [UInt8](repeating: 0, count: 256)
            lookup.withUnsafeBufferPointer { table in
                withUnsafeMutablePointer(to: &byte) { input in
                    withUnsafeMutablePointer(to: &out) { output in
                        _ = AemiKernels.base64DecodeBlocks(
                            lookup: table,
                            tail: 0,
                            input: UnsafeBufferPointer(start: input, count: 1 << 40),
                            output: UnsafeMutableBufferPointer(start: output, count: 1)
                        )
                    }
                }
            }
        }
    }

    @Test func `a negative line width traps`() async {
        await #expect(processExitsWith: .failure) {
            let lookup = [UInt8](repeating: 0, count: 256)
            let input = [UInt8](repeating: 0x41, count: 80)
            var out = [UInt8](repeating: 0, count: 80)
            _ = lookup.withUnsafeBufferPointer { table in
                input.withUnsafeBufferPointer { source in
                    out.withUnsafeMutableBufferPointer {
                        AemiKernels.base64DecodeLines(lookup: table, tail: 0, input: source, output: $0, width: -76)
                    }
                }
            }
        }
    }

    @Test func `a percent decode output shorter than a huge input traps before the kernel runs`() async {
        await #expect(processExitsWith: .failure) {
            var byte: UInt8 = 0x25
            var out: UInt8 = 0
            withUnsafeMutablePointer(to: &byte) { input in
                withUnsafeMutablePointer(to: &out) { output in
                    _ = AemiKernels.percentDecode(
                        UnsafeBufferPointer(start: input, count: 1 << 40),
                        into: UnsafeMutableBufferPointer(start: output, count: 1),
                        plusAsSpace: false
                    )
                }
            }
        }
    }

    @Test func `an empty needle, an empty haystack and a needle longer than the haystack are answered without reading`()
    {
        let empty = UnsafeBufferPointer<UInt8>(start: nil, count: 0)
        [UInt8(1), 2, 3]
            .withUnsafeBufferPointer { three in
                #expect(AemiKernels.firstIndex(of: empty, in: three) == 0)
                #expect(AemiKernels.firstIndex(of: three, in: empty) == nil)
                #expect(AemiKernels.firstIndex(of: three, in: UnsafeBufferPointer(rebasing: three[0 ..< 2])) == nil)
            }
    }
}

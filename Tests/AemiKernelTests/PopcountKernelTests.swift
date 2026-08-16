import AemiKernel
import AemiTestKit
import Testing

// `Popcount.hammingDistance` now routes to the SIMD kernel; it must stay bit-identical to the byte-LUT
// reference (`hammingDistanceLUT`) — the wire regression gate.
struct PopcountKernelTests {
    @Test func hammingMatchesLUTFuzzed() {
        var rng = SeededRNG(seed: 0xBADF_00D1_2345_6789)
        let widths = [0, 1, 7, 8, 16, 63, 64, 65, 100, 256]
        var mismatches = 0
        for _ in 0 ..< 3000 {
            let width = widths[rng.int(widths.count)]
            var a: [UInt8] = []
            var b: [UInt8] = []
            for _ in 0 ..< width {
                a.append(UInt8(rng.int(256)))
                b.append(UInt8(rng.int(256)))
            }
            let viaKernel = a.withUnsafeBytes { pa in
                b.withUnsafeBytes { pb in Popcount.hammingDistance(pa, pb, count: width) }
            }
            let viaLUT = a.withUnsafeBytes { pa in
                b.withUnsafeBytes { pb in Popcount.hammingDistanceLUT(pa, pb, count: width) }
            }
            if viaKernel != viaLUT { mismatches += 1 }
        }
        #expect(mismatches == 0)
    }
}

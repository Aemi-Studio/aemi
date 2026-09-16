import AemiFoundation
import Testing

/// The umbrella must surface every runtime tier the manifest declares for it, through one import.
/// Each assertion names a symbol from a different re-exported module, so a dropped `@_exported`
/// fails here rather than in a consumer.
struct ExportsTests {
    @Test
    func `the umbrella re-exports every runtime tier`() {
        // AemiKernels: runtime-dispatched SIMD byte kernels.
        #expect(!AemiKernels.activeBackend.isEmpty)
        #expect(AemiKernels.firstIndexOfByte(UInt8(ascii: "b"), in: Array("abc".utf8)) == 1)
        // AemiKernel: pure-Swift byte primitives.
        #expect(XXH64.hash(Array("abc".utf8)) == XXH64.hash(Array("abc".utf8)))
        // AemiText, AemiUnicode, AemiIO, AemiMetrics, AemiRuntime.
        #expect(AemiText.editDistance(Array("kitten".utf8), Array("sitting".utf8)) == 3)
        #expect(CaseFolding.lowercase(Array("A".unicodeScalars)) == Array("a".unicodeScalars))
        #expect(IOError(errno: 2, op: "open").errno == 2)
        #expect(ProcessProbe.monotonicNanos() > 0)
        #expect(LiveClock.monotonicNanoseconds() > 0)
    }
}

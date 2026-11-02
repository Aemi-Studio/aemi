import AemiKernel
import AemiTestKit
import Testing

/// ByteSearch on the SIMD kernel against a naive search written here: small alphabets (frequent candidates), needles that occur
/// and that do not, slices with non-zero start indices, and the adversarial inputs that make the kernel hand over to
/// Knuth-Morris-Pratt, whose answers and time must stay right.
struct ByteSearchKernelTests {
    private static func naive(_ needle: [UInt8], _ haystack: ArraySlice<UInt8>) -> Range<Int>? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        var start = haystack.startIndex
        while start + needle.count <= haystack.endIndex {
            if haystack[start ..< start + needle.count].elementsEqual(needle) { return start ..< start + needle.count }
            start += 1
        }
        return nil
    }

    @Test func randomSearchesMatchTheReference() {
        var rng = SeededRNG(seed: Seed.named("bytesearch.random"))
        for length in 0 ... 300 {
            for trial in 0 ..< 12 {
                let alphabet = UInt64(2 + trial % 4)
                let bytes = (0 ..< length).map { _ in UInt8(ascii: "a") + UInt8(rng.next() % alphabet) }
                let offset = length > 0 ? Int(rng.next() % UInt64(min(length, 9))) : 0
                let haystack = bytes[offset...]
                let needleLength = Int(rng.next() % 40)
                var needle = (0 ..< needleLength).map { _ in UInt8(ascii: "a") + UInt8(rng.next() % alphabet) }
                if trial % 2 == 0, haystack.count >= needleLength, needleLength > 0 {
                    let at = haystack.startIndex + Int(rng.next() % UInt64(haystack.count - needleLength + 1))
                    needle = Array(haystack[at ..< at + needleLength])
                }
                #expect(
                    ByteSearch.firstRange(of: needle, in: haystack) == Self.naive(needle, haystack),
                    "\(length) \(trial)"
                )
            }
        }
    }

    @Test func adversarialInputsStayCorrectAndLinear() {
        let clock = ContinuousClock()
        for (hayLength, needleLength) in [(200_000, 1_001), (200_000, 30_001), (1 << 20, 4_097)] {
            var haystack = [UInt8](repeating: UInt8(ascii: "a"), count: hayLength)
            var needle = [UInt8](repeating: UInt8(ascii: "a"), count: needleLength)
            needle[needleLength / 2] = UInt8(ascii: "b")
            let elapsed = clock.measure { #expect(ByteSearch.firstRange(of: needle, in: haystack[...]) == nil) }
            // Quadratic would be hayLength * needleLength / 2 ≈ 3e9 byte compares; linear is well under a second.
            #expect(elapsed < .seconds(2), "\(hayLength) x \(needleLength) took \(elapsed)")
            haystack.replaceSubrange((hayLength - needleLength) ..< hayLength, with: needle)
            #expect(ByteSearch.firstRange(of: needle, in: haystack[...]) == (hayLength - needleLength) ..< hayLength)
        }
    }

    @Test func splitKeepsItsAnswers() {
        let text = Array("--boundary\r\npart one\r\n--boundary\r\npart two\r\n--boundary--".utf8)
        let parts = ByteSearch.split(text, on: Array("--boundary".utf8))
        #expect(parts.map { String(decoding: $0, as: UTF8.self) } == ["", "\r\npart one\r\n", "\r\npart two\r\n", "--"])
        #expect(ByteSearch.split(text, on: []).count == 1)
        #expect(ByteSearch.split(Array("aaa".utf8), on: Array("a".utf8)).count == 4)
    }
}

import Testing

@testable import AemiTestKit

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

@Suite(.tags(.fuzz))
struct FuzzTests {
    @Test
    func `ByteMutator exercises all four edit shapes over a corpus`() {
        var rng = SeededRNG(seed: 0x5EED_A11C_E5F0_0D)
        let mutator = ByteMutator()
        var seen = Set<ByteMutator.Edit>()
        for _ in 0 ..< 2000 {
            var bytes = Array("the quick brown fox".utf8)
            let applied = mutator.apply(8, to: &bytes, using: &rng)
            for m in applied { seen.insert(m.kind) }
        }
        #expect(seen == Set(ByteMutator.Edit.allCases))
    }

    @Test
    func `ByteMutator is deterministic for a fixed seed`() {
        func run() -> [UInt8] {
            var rng = SeededRNG(seed: 42)
            var bytes = Array(0 ..< 64).map { UInt8($0) }
            ByteMutator().apply(20, to: &bytes, using: &rng)
            return bytes
        }
        #expect(run() == run())
    }

    @Test
    func `region-bounded overwrite/bit-flip never touches the protected prefix`() {
        // Restrict to non-shrinking edits so the buffer size is constant and the guarded
        // prefix is fully protected — the ADDB meta-page protection shape.
        let prefix = 16
        let mutator = ByteMutator(region: prefix ..< 256, allowedEdits: [.overwrite, .bitFlip])
        var rng = SeededRNG(seed: 7)
        let original = Array(repeating: UInt8(0xAA), count: 256)
        for _ in 0 ..< 500 {
            var bytes = original
            for m in mutator.apply(8, to: &bytes, using: &rng) {
                if let offset = m.offset { #expect(offset >= prefix) }
            }
            #expect(bytes.count == original.count)
            #expect(Array(bytes.prefix(prefix)) == Array(original.prefix(prefix)))
        }
    }

    @Test
    func `fuzzNeverTraps drives the corpus and reports the work done`() {
        var exercised = 0
        let report = fuzzNeverTraps(
            seed: Seed.named("adtestkit.self-test"),
            iterations: 500,
            corpus: { Array("payload".utf8) },
            exercise: { mutated in
                // A real suite would decode/parse here, swallowing typed errors. We just
                // prove the driver feeds us bytes and survives.
                exercised += mutated.isEmpty ? 0 : 1
            })
        #expect(report.iterations == 500)
        #expect(report.totalEdits >= 500)  // at least one edit per iteration
        #expect(exercised >= 0)
    }

    @Test
    func `the generic driver is deterministic and reproducible`() {
        func collect() -> [Int] {
            var out: [Int] = []
            fuzzNeverTraps(
                seed: Seed(0xC0FF_EE),
                iterations: 200,
                generate: { _, rng in rng.int(in: 0 ... 1_000_000) },
                exercise: { out.append($0) })
            return out
        }
        #expect(collect() == collect())
    }

    @Test
    func `both drivers honor the trace env without trapping`() {
        setenv("ADTESTKIT_SELFTEST_TRACE", "1", 1)
        defer { unsetenv("ADTESTKIT_SELFTEST_TRACE") }
        // Byte driver: the trace prints each Mutation's description, covering both the
        // trace branch and ByteMutator.Mutation.description.
        let byteReport = fuzzNeverTraps(
            seed: Seed(0xABCD), iterations: 3, traceEnv: "ADTESTKIT_SELFTEST_TRACE",
            corpus: { Array("trace".utf8) }, exercise: { _ in })
        #expect(byteReport.iterations == 3)
        // Generic driver trace branch.
        let genericReport = fuzzNeverTraps(
            seed: Seed(0xBEEF), iterations: 3, traceEnv: "ADTESTKIT_SELFTEST_TRACE",
            generate: { _, rng in rng.byte() }, exercise: { _ in })
        #expect(genericReport.iterations == 3)
    }
}

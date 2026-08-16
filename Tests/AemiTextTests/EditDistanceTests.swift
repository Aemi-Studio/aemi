import AemiText
import AemiTestKit
import Testing

// The randomized cross-checks use the shared `AemiTestKit.SeededRNG` (its `int(_:)` has the
// same contract as the old local `LCG`). These are property tests — banded == full, and
// symmetry — so they hold under any deterministic seeded stream; the seeds are preserved.

struct EditDistanceTests {
    private func dist(_ a: String, _ b: String, max: Int = .max) -> Int {
        AemiText.editDistance(Array(a.utf8), Array(b.utf8), maxDistance: max)
    }

    @Test func exactDistances() {
        #expect(dist("", "") == 0)
        #expect(dist("abc", "abc") == 0)
        #expect(dist("", "abc") == 3)
        #expect(dist("abc", "") == 3)
        #expect(dist("kitten", "sitting") == 3)
        #expect(dist("flaw", "lawn") == 2)
        #expect(dist("a", "b") == 1)
    }

    @Test func earlyExitReturnsMaxPlusOneWhenExceeded() {
        #expect(dist("a", "abcdef", max: 2) == 3)
        #expect(dist("kitten", "sitting", max: 3) == 3)
        #expect(dist("abcd", "wxyz", max: 2) == 3)
    }

    @Test func worksOverArbitraryEquatableElements() {
        #expect(AemiText.editDistance([1, 2, 3], [1, 2, 3]) == 0)
        #expect(AemiText.editDistance([1, 2, 3], [1, 4, 3]) == 1)
        #expect(AemiText.editDistance(Array("café".utf16), Array("cafe".utf16)) == 1)
    }

    /// Exhaustive: every pair of strings of length ≤ 3 over {a,b,c}, every bound 0…4. Banded and the
    /// adaptive dispatcher must equal the full (exact) distance clamped to the bound.
    @Test func bandedMatchesFullExhaustively() {
        let alphabet: [UInt8] = [97, 98, 99]
        var corpus: [[UInt8]] = [[]]
        var frontier: [[UInt8]] = [[]]
        for _ in 0 ..< 3 {
            var next: [[UInt8]] = []
            for s in frontier { for c in alphabet { next.append(s + [c]) } }
            corpus += next
            frontier = next
        }
        var failures: [String] = []
        for a in corpus {
            for b in corpus {
                let full = AemiText.editDistanceFull(a, b)
                for k in 0 ... 4 {
                    let expected = full <= k ? full : k + 1
                    let banded = AemiText.editDistanceBanded(a, b, maxDistance: k)
                    if banded != expected {
                        failures.append("banded(\(a),\(b),k=\(k))=\(banded) != \(expected) full=\(full)")
                    }
                    let adaptive = AemiText.editDistance(a, b, maxDistance: k)
                    if adaptive != expected { failures.append("adaptive(\(a),\(b),k=\(k))=\(adaptive) != \(expected)") }
                }
            }
        }
        #expect(failures.isEmpty, "\(failures.prefix(8))")
    }

    /// Long inputs (rows past the banded dispatch threshold), so the adaptive path actually selects
    /// the banded matrix; checked against the full matrix for several bounds.
    @Test func bandedMatchesFullOnLongInputs() {
        var rng = SeededRNG(seed: 0x9E37_79B9_7F4A_7C15)
        var failures = 0
        for _ in 0 ..< 400 {
            let length = 16 + rng.int(96)  // 16…111, straddles the bandedMinRowWidth threshold
            let a = (0 ..< length).map { _ in UInt8(97 + rng.int(5)) }
            var b = a
            for _ in 0 ..< rng.int(10) where !b.isEmpty { b[rng.int(b.count)] = UInt8(97 + rng.int(5)) }
            for k in [0, 1, 2, 3, 5, 10, 50] {
                let full = AemiText.editDistanceFull(a, b)
                let expected = full <= k ? full : k + 1
                if AemiText.editDistanceBanded(a, b, maxDistance: k) != expected { failures += 1 }
                if AemiText.editDistance(a, b, maxDistance: k) != expected { failures += 1 }
            }
        }
        #expect(failures == 0)
    }

    /// Edit distance is symmetric; the internal min-orientation must preserve that for both the
    /// unbounded and the bounded contract.
    @Test func isSymmetric() {
        var rng = SeededRNG(seed: 0xABCD_1234_5678_9F01)
        for _ in 0 ..< 500 {
            let a = (0 ..< rng.int(40)).map { _ in UInt8(97 + rng.int(4)) }
            let b = (0 ..< rng.int(40)).map { _ in UInt8(97 + rng.int(4)) }
            #expect(AemiText.editDistance(a, b) == AemiText.editDistance(b, a))
            for k in [0, 1, 3, 10] {
                #expect(
                    AemiText.editDistance(a, b, maxDistance: k) == AemiText.editDistance(b, a, maxDistance: k))
            }
        }
    }

    /// `m == 1` against a large `n` drives the min-orientation + temporary-allocation row sizing.
    @Test func highlyAsymmetricInputs() {
        let one: [UInt8] = [UInt8(ascii: "x")]
        let manyY = [UInt8](repeating: UInt8(ascii: "y"), count: 5000)
        let manyX = [UInt8](repeating: UInt8(ascii: "x"), count: 5000)
        #expect(AemiText.editDistance(one, manyY) == 5000)  // 1 substitution + 4999 insertions
        #expect(AemiText.editDistance(manyY, one) == 5000)  // symmetric
        #expect(AemiText.editDistance(one, manyX) == 4999)  // one 'x' matches; 4999 insertions
    }

    /// The pure functions are safe to fan out concurrently (no shared state).
    @Test func concurrentCallsAgree() async {
        let pairs: [(String, String)] = [
            ("kitten", "sitting"), ("flaw", "lawn"), ("foundation", "fundamentals"), ("", "abc")
        ]
        let serial = pairs.map { dist($0.0, $0.1) }
        let parallel = await withTaskGroup(of: (Int, Int).self) { group in
            for (i, p) in pairs.enumerated() {
                group.addTask { (i, AemiText.editDistance(Array(p.0.utf8), Array(p.1.utf8))) }
            }
            var out = [Int](repeating: -1, count: pairs.count)
            for await (i, d) in group { out[i] = d }
            return out
        }
        #expect(serial == parallel)
    }
}

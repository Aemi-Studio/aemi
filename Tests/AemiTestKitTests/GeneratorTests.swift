import Testing

@testable import AemiTestKit

// Property-based harness self-tests: `forAll` returns nil when the invariant holds, and on a failure it
// shrinks to the MINIMAL counterexample (the exact boundary / single offending element), deterministically
// from the seed. These assertions are themselves mutation-resistant — they pin the minimal value, so a
// regression in the shrink descent (stopping early, wrong direction) changes the reported value and fails.
@Suite(.tags(.property))
struct GeneratorTests {
    @Test
    func `forAll returns nil when the property holds for every value`() {
        #expect(forAll(Gen.int(in: 0 ... 1000)) { $0 >= 0 } == nil)
        #expect(forAll(Gen.string()) { _ in true } == nil)
    }

    @Test
    func `forAll shrinks an int boundary failure to the exact boundary`() {
        // `value < 50` fails at 50; the halving-approach shrinker must descend precisely to 50.
        let minimal = withKnownIssue { forAll(Gen.int(in: 0 ... 100)) { $0 < 50 } } ?? nil
        #expect(minimal == 50)
    }

    @Test
    func `forAll shrinks a string failure to the single offending character`() {
        let minimal = withKnownIssue { forAll(Gen.string()) { !$0.contains("<") } } ?? nil
        #expect(minimal == "<")
    }

    @Test
    func `forAll shrinks an array failure to the minimal failing length`() {
        // `count < 5` fails at 5; element-dropping shrink must bottom out at exactly 5 elements.
        let minimal = withKnownIssue { forAll(Gen.array(of: Gen.int(in: 0 ... 9))) { $0.count < 5 } } ?? nil
        #expect(minimal?.count == 5)
    }

    @Test
    func `forAll is deterministic — the same seed reports the same counterexample`() {
        let seed = Seed.named("generator-determinism")
        let first = withKnownIssue { forAll(Gen.int(in: 0 ... 100), seed: seed) { $0 < 50 } } ?? nil
        let second = withKnownIssue { forAll(Gen.int(in: 0 ... 100), seed: seed) { $0 < 50 } } ?? nil
        #expect(first == second)
    }

    @Test
    func `map transforms generated values`() {
        // A mapped generator still drives forAll; the property holds, so nil.
        #expect(forAll(Gen.int(in: 1 ... 9).map { String($0) }) { $0.count == 1 } == nil)
    }
}

/// Runs `body`, swallowing the issue `forAll` records on a property failure (the failure is EXPECTED here —
/// we are testing the shrinker), and returns `body`'s value (the minimal counterexample) for assertion.
private func withKnownIssue<T>(_ body: () -> T) -> T? {
    var captured: T?
    Testing.withKnownIssue { captured = body() }
    return captured
}

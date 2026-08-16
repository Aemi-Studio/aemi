// `public import`: `forAll` exposes Swift Testing's `SourceLocation` publicly.
public import Testing

// Property-based testing for the AD-family: a `Generator` produces seeded random inputs, `forAll` runs a
// property over many of them, and on the first failure it SHRINKS to a minimal counterexample before
// recording one issue — the QuickCheck model, built on the existing `SeededRNG` so a failure reproduces
// from its seed. This is the one piece the kit lacked (it already had byte-level `ByteMutator`/`SeededRNG`
// fuzzing and the `expectRoundTripIdentity`/`expectThrows`/`ReferenceComparison` oracles); a property test
// asserts an invariant over *structured* inputs, complementing those. Shrinking is ITERATIVE (no recursion
// — the kit's own discipline): a greedy descent that repeatedly replaces the failing value with the first
// smaller candidate that still fails, until none does.

/// Produces values of `Value` from a `SeededRNG` and knows how to SHRINK a value toward simpler ones (for
/// minimal-counterexample reporting). `shrink` returns strictly "smaller" candidates (fewer elements,
/// closer to a base value) and must eventually bottom out at `[]` so the descent terminates.
public protocol Generator<Value> {
    associatedtype Value
    /// One random value. Consume `rng` deterministically so a pinned seed reproduces the same draw.
    func generate(using rng: inout SeededRNG) -> Value
    /// Strictly-smaller candidates to try when minimizing a failing value (default: none).
    func shrink(_ value: Value) -> [Value]
}

extension Generator {
    public func shrink(_ value: Value) -> [Value] { [] }

    /// Transform every produced value. Shrinking is dropped (the inverse map is unknown), which is safe —
    /// a mapped generator simply reports its (already-small) input value unshrunk.
    public func map<T>(_ transform: @escaping (Value) -> T) -> AnyGenerator<T> {
        AnyGenerator(generate: { rng in transform(self.generate(using: &rng)) })
    }

    /// Keep only values satisfying `isIncluded`, redrawing up to `maxAttempts` times (then yielding the
    /// last draw — never hangs). Shrink candidates are likewise filtered, so minimization stays in-domain.
    public func filter(maxAttempts: Int = 100, _ isIncluded: @escaping (Value) -> Bool) -> AnyGenerator<Value> {
        AnyGenerator(
            generate: { rng in
                var last = self.generate(using: &rng)
                var attempt = 1
                while attempt < maxAttempts && !isIncluded(last) {
                    last = self.generate(using: &rng)
                    attempt += 1
                }
                return last
            },
            shrink: { value in self.shrink(value).filter(isIncluded) })
    }
}

/// A type-erased `Generator` backed by closures — the workhorse returned by every `Gen` factory and by
/// `map`/`filter`. `shrink` defaults to "no smaller candidates".
public struct AnyGenerator<Value>: Generator {
    private let _generate: (inout SeededRNG) -> Value
    private let _shrink: (Value) -> [Value]

    public init(
        generate: @escaping (inout SeededRNG) -> Value,
        shrink: @escaping (Value) -> [Value] = { _ in [] }
    ) {
        self._generate = generate
        self._shrink = shrink
    }

    public func generate(using rng: inout SeededRNG) -> Value { _generate(&rng) }
    public func shrink(_ value: Value) -> [Value] { _shrink(value) }
}

/// Factory namespace for the common generators. Each carries a shrinker that descends toward a minimal
/// value (the empty collection, the range's lower bound), so `forAll` reports the smallest input that
/// still breaks the property.
public enum Gen {
    /// An `Int` in `range`, shrinking toward `range.lowerBound`: the lower bound first (most aggressive),
    /// then a halving sequence that *approaches* `value` from below, so a boundary property (`value < K`
    /// fails) minimizes to the exact boundary rather than to any large value.
    public static func int(in range: ClosedRange<Int>) -> AnyGenerator<Int> {
        AnyGenerator(
            generate: { rng in rng.int(in: range) },
            shrink: { value in
                guard value > range.lowerBound else { return [] }
                var seen = Set<Int>()
                var candidates: [Int] = []
                if seen.insert(range.lowerBound).inserted { candidates.append(range.lowerBound) }
                var gap = value - range.lowerBound
                while gap > 1 {
                    gap /= 2
                    let candidate = value - gap  // approaches `value` from below as the gap halves
                    if candidate > range.lowerBound, candidate < value, seen.insert(candidate).inserted {
                        candidates.append(candidate)
                    }
                }
                return candidates
            })
    }

    /// A `Bool`; shrinks `true` toward `false`.
    public static var bool: AnyGenerator<Bool> {
        AnyGenerator(generate: { rng in rng.bool() }, shrink: { $0 ? [false] : [] })
    }

    /// A single byte, shrinking toward 0.
    public static var byte: AnyGenerator<UInt8> {
        AnyGenerator(
            generate: { rng in rng.byte() },
            shrink: { value in value == 0 ? [] : [0, value / 2].filter { $0 != value } })
    }

    /// A uniformly chosen element of `items` (`items` must be non-empty); shrinks toward the first element.
    public static func element<T>(of items: [T]) -> AnyGenerator<Int> {
        precondition(!items.isEmpty, "Gen.element requires a non-empty array")
        return int(in: 0 ... (items.count - 1))
    }

    /// One of the supplied generators, chosen per draw; shrinking defers to the chosen generator is not
    /// possible after erasure, so `oneOf` reports its value unshrunk (compose with `array`/`int` for depth).
    public static func oneOf<T>(_ generators: [AnyGenerator<T>]) -> AnyGenerator<T> {
        precondition(!generators.isEmpty, "Gen.oneOf requires at least one generator")
        return AnyGenerator(generate: { rng in generators[rng.uniform(generators.count)].generate(using: &rng) })
    }

    /// An array of up to `maxCount` elements. Shrinks by removing elements (empty first, then each index
    /// dropped) and by shrinking individual elements — the standard collection shrink.
    public static func array<G: Generator>(of element: G, maxCount: Int = 16) -> AnyGenerator<[G.Value]> {
        AnyGenerator(
            generate: { rng in
                let count = rng.uniform(maxCount + 1)
                var values: [G.Value] = []
                values.reserveCapacity(count)
                for _ in 0 ..< count { values.append(element.generate(using: &rng)) }
                return values
            },
            shrink: { values in
                guard !values.isEmpty else { return [] }
                var candidates: [[G.Value]] = [[]]
                if values.count > 1 { candidates.append(Array(values.prefix(values.count / 2))) }
                for index in values.indices {  // each element dropped
                    var without = values
                    without.remove(at: index)
                    candidates.append(without)
                }
                return candidates
            })
    }

    /// Raw bytes (an `array(of: byte)`), capped at `maxCount`.
    public static func bytes(maxCount: Int = 64) -> AnyGenerator<[UInt8]> {
        array(of: byte, maxCount: maxCount)
    }

    /// A `String` drawn from `alphabet` (default: a mix of safe ASCII and HTML/JS metacharacters, so an
    /// escaper property exercises both the fast run and every escape branch). Shrinks like its byte array.
    public static func string(
        maxLength: Int = 32,
        alphabet: [Character] = Array("ab09 \t\n<>&\"'/\\`{}=;:#")
    ) -> AnyGenerator<String> {
        precondition(!alphabet.isEmpty, "Gen.string requires a non-empty alphabet")
        return AnyGenerator(
            generate: { rng in
                let count = rng.uniform(maxLength + 1)
                var characters: [Character] = []
                characters.reserveCapacity(count)
                for _ in 0 ..< count { characters.append(alphabet[rng.uniform(alphabet.count)]) }
                return String(characters)
            },
            shrink: { value in
                guard !value.isEmpty else { return [] }
                let characters = Array(value)
                var candidates: [String] = [""]
                if characters.count > 1 { candidates.append(String(characters.prefix(characters.count / 2))) }
                for index in characters.indices {
                    var without = characters
                    without.remove(at: index)
                    candidates.append(String(without))
                }
                return candidates
            })
    }
}

/// Runs `property` over `count` generated values from a pinned `seed`. On the first value for which the
/// property returns `false` (or throws), SHRINKS to a locally-minimal failing value and records ONE issue
/// naming it — so a property failure points at the smallest reproducer, not a noisy random one. Returns
/// the minimal counterexample (or `nil` if the property held for every value). Deterministic: the same
/// seed replays the same inputs, so a recorded failure reproduces exactly.
@discardableResult
public func forAll<G: Generator>(
    _ generator: G,
    count: Int = 200,
    seed: Seed = .named("adtestkit.forAll"),
    sourceLocation: SourceLocation = #_sourceLocation,
    _ property: (G.Value) throws -> Bool
) -> G.Value? {
    // A value "fails" if the property returns false or throws — both mean the invariant didn't hold.
    func fails(_ value: G.Value) -> Bool { ((try? property(value)) ?? false) == false }

    var rng = SeededRNG(seed: seed)
    for iteration in 0 ..< count {
        let value = generator.generate(using: &rng)
        guard fails(value) else { continue }

        // Greedy iterative shrink (no recursion): repeatedly adopt the first strictly-smaller candidate
        // that still fails, until no shrink candidate fails. Bounded by `shrink` bottoming out at [].
        var minimal = value
        descend: while true {
            for candidate in generator.shrink(minimal) where fails(candidate) {
                minimal = candidate
                continue descend
            }
            break
        }
        Issue.record(
            """
            property failed (iteration \(iteration), seed \(seed.rawValue)); \
            minimal counterexample: \(String(reflecting: minimal))
            """,
            sourceLocation: sourceLocation)
        return minimal
    }
    return nil
}

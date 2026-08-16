// `public import`: the oracle asserts expose Swift Testing's `SourceLocation` publicly.
public import Testing

/// Generic reference-model comparison, lifted from `SQLiteMirror`'s `rowsMatch` /
/// `lexLess` / NaN-aware `valueMatches` so every oracle suite (SQLite mirror, JS
/// oracle, tape-vs-SAX parity) shares one row-set comparator instead of re-rolling
/// it. The element type and its equality are caller-supplied, so a float column can
/// pass a NaN-aware compare while everything else uses `==`.
public enum ReferenceComparison {
    /// Compares two row sets. When `ordered` is false the rows are sorted by
    /// `precedes` into a canonical order first, giving a multiset (bag) comparison;
    /// element equality is decided by `matches`.
    public static func rowsMatch<E>(
        _ ours: [[E]],
        _ theirs: [[E]],
        ordered: Bool,
        matches: (E, E) -> Bool,
        precedes: ([E], [E]) -> Bool
    ) -> Bool {
        guard ours.count == theirs.count else { return false }
        let lhs = ordered ? ours : ours.sorted(by: precedes)
        let rhs = ordered ? theirs : theirs.sorted(by: precedes)
        for (a, b) in zip(lhs, rhs) {
            guard a.count == b.count else { return false }
            for (x, y) in zip(a, b) where !matches(x, y) { return false }
        }
        return true
    }

    /// `Equatable` convenience: element equality is `==` and the multiset order is a
    /// lexicographic fold over a caller-supplied element order.
    public static func rowsMatch<E: Equatable>(
        _ ours: [[E]],
        _ theirs: [[E]],
        ordered: Bool,
        elementOrder: (E, E) -> Int
    ) -> Bool {
        rowsMatch(
            ours, theirs, ordered: ordered,
            matches: { $0 == $1 },
            precedes: { lexicographicallyPrecedes($0, $1, elementOrder: elementOrder) })
    }

    /// A deterministic total order over rows from a per-element comparator returning
    /// negative / zero / positive — the generic form of the oracle's `lexLess`.
    public static func lexicographicallyPrecedes<E>(
        _ a: [E], _ b: [E], elementOrder: (E, E) -> Int
    ) -> Bool {
        for i in 0 ..< min(a.count, b.count) {
            let c = elementOrder(a[i], b[i])
            if c != 0 { return c < 0 }
        }
        return a.count < b.count
    }

    /// NaN-aware float equality: equal, or both NaN — the generic `valueMatches` core.
    public static func floatMatches<F: BinaryFloatingPoint>(_ a: F, _ b: F) -> Bool {
        a == b || (a.isNaN && b.isNaN)
    }
}

/// Asserts `expression` throws a `E`-typed error whose *payload* satisfies `predicate`
/// — codifying the AD-family's zero-`#expect(throws: Error.self)` discipline. A weak
/// "it threw something" is never enough: the error must be the expected concrete type
/// *and* carry the expected case/associated value. Returns the caught error for
/// further inspection. Routes every failure (returned normally / wrong type / rejected
/// payload) to `Issue.record` — it never traps the runner.
@discardableResult
public func expectThrows<T, E: Error>(
    _ expression: () throws -> T,
    sourceLocation: SourceLocation = #_sourceLocation,
    where predicate: (E) -> Bool
) -> E? {
    do {
        _ = try expression()
        Issue.record(
            "expected to throw \(E.self), but returned normally", sourceLocation: sourceLocation)
        return nil
    } catch let error as E {
        if predicate(error) { return error }
        Issue.record(
            "threw \(error) but its payload was rejected by the predicate",
            sourceLocation: sourceLocation)
        return error
    } catch {
        Issue.record("threw \(error) — not the expected \(E.self)", sourceLocation: sourceLocation)
        return nil
    }
}

/// Async form of `expectThrows(_:where:)`.
@discardableResult
public func expectThrows<T, E: Error>(
    _ expression: () async throws -> T,
    sourceLocation: SourceLocation = #_sourceLocation,
    where predicate: (E) -> Bool
) async -> E? {
    do {
        _ = try await expression()
        Issue.record(
            "expected to throw \(E.self), but returned normally", sourceLocation: sourceLocation)
        return nil
    } catch let error as E {
        if predicate(error) { return error }
        Issue.record(
            "threw \(error) but its payload was rejected by the predicate",
            sourceLocation: sourceLocation)
        return error
    } catch {
        Issue.record("threw \(error) — not the expected \(E.self)", sourceLocation: sourceLocation)
        return nil
    }
}

/// Asserts `value` survives a round trip unchanged (encode→decode, serialize→parse,
/// tape→tree→tape). Generalizes ADJSON's `expectRoundTrips`. A thrown error or an
/// unequal result is recorded; the runner is never trapped.
public func expectRoundTripIdentity<V: Equatable>(
    _ value: V,
    sourceLocation: SourceLocation = #_sourceLocation,
    via roundTrip: (V) throws -> V
) {
    do {
        let result = try roundTrip(value)
        if result != value {
            Issue.record(
                "round trip changed the value: \(value) → \(result)", sourceLocation: sourceLocation
            )
        }
    } catch {
        Issue.record("round trip threw: \(error)", sourceLocation: sourceLocation)
    }
}

/// Asserts two independent computations of the same value agree (tape-vs-SAX,
/// cross-path number parsing, mirror-vs-engine). Records a labeled issue on
/// divergence.
public func expectParity<V: Equatable>(
    _ lhs: V,
    _ rhs: V,
    _ label: String = "parity",
    sourceLocation: SourceLocation = #_sourceLocation
) {
    if lhs != rhs {
        Issue.record("\(label) mismatch: \(lhs) != \(rhs)", sourceLocation: sourceLocation)
    }
}

/// Row-set parity through `ReferenceComparison`, for the SQLite-mirror / engine
/// differential oracles. Records the two row sets on divergence.
public func expectParity<E: Equatable>(
    rows ours: [[E]],
    _ theirs: [[E]],
    ordered: Bool,
    elementOrder: (E, E) -> Int,
    _ label: String = "row parity",
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let match = ReferenceComparison.rowsMatch(
        ours, theirs, ordered: ordered, elementOrder: elementOrder)
    if !match {
        Issue.record(
            "\(label) mismatch:\n  ours:   \(ours)\n  theirs: \(theirs)",
            sourceLocation: sourceLocation)
    }
}

// `public import`: the typed asserts expose Swift Testing's `SourceLocation` (with `#_sourceLocation`
// defaults) in their public signatures, so under `InternalImportsByDefault` Testing is public here.
public import Testing

// Typed asserts that defuse the type-check-timing flake. The four `treatAllWarnings`
// packages also set `-warn-long-expression-type-checking=100`, so one heavy inferred
// expression fails the build under load. `#expect(bigChainedExpression == [literal,
// …])` forces the solver to type-check the whole boolean (operands + inline literal)
// as a single constraint system. These plain generic functions instead let each
// operand type-check independently against `T`, and let the author bind a big literal
// to its own explicitly-typed `let` (fast) before passing it — splitting the
// megaexpression so every piece stays under budget. They route failures to
// `Issue.record`, so they never trap the runner.

/// Typed equality assert. Prefer over `#expect(a == b)` for hot expressions.
public func expectEqual<T: Equatable>(
    _ actual: T,
    _ expected: T,
    _ label: String = "",
    sourceLocation: SourceLocation = #_sourceLocation
) {
    if actual != expected {
        let prefix = label.isEmpty ? "" : "\(label): "
        Issue.record("\(prefix)expected \(expected), got \(actual)", sourceLocation: sourceLocation)
    }
}

/// Typed array equality with element-wise divergence reporting. The explicit `[T]`
/// operands keep the solver off a giant inferred literal inside a macro.
public func expectEqual<T: Equatable>(
    _ actual: [T],
    _ expected: [T],
    _ label: String = "",
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let prefix = label.isEmpty ? "" : "\(label): "
    guard actual.count == expected.count else {
        Issue.record(
            "\(prefix)count \(actual.count) != \(expected.count)\n  actual:   \(actual)\n  expected: \(expected)",
            sourceLocation: sourceLocation)
        return
    }
    let cap = 10
    var reported = 0
    for (index, (a, b)) in zip(actual, expected).enumerated() where a != b {
        guard reported < cap else {
            Issue.record(
                "\(prefix)… and more (showing the first \(cap) divergences)",
                sourceLocation: sourceLocation)
            break
        }
        Issue.record("\(prefix)element[\(index)] \(a) != \(b)", sourceLocation: sourceLocation)
        reported += 1
    }
}

/// Typed inequality assert.
public func expectNotEqual<T: Equatable>(
    _ actual: T,
    _ unexpected: T,
    _ label: String = "",
    sourceLocation: SourceLocation = #_sourceLocation
) {
    if actual == unexpected {
        let prefix = label.isEmpty ? "" : "\(label): "
        Issue.record(
            "\(prefix)expected a value other than \(unexpected)", sourceLocation: sourceLocation)
    }
}

/// Typed `Bool` assert — avoids re-type-checking a boolean expression inside a macro.
public func expectTrue(
    _ value: Bool,
    _ label: String = "expected true",
    sourceLocation: SourceLocation = #_sourceLocation
) {
    if !value { Issue.record("\(label)", sourceLocation: sourceLocation) }
}

public func expectFalse(
    _ value: Bool,
    _ label: String = "expected false",
    sourceLocation: SourceLocation = #_sourceLocation
) {
    if value { Issue.record("\(label)", sourceLocation: sourceLocation) }
}

/// Asserts non-nil and *returns the unwrapped value* — so an existence-only `!= nil`
/// weak assert can be upgraded to "unwrap, then assert on the contents". Records and
/// returns `nil` on failure rather than trapping.
@discardableResult
public func expectNotNil<T>(
    _ value: T?,
    _ label: String = "expected non-nil",
    sourceLocation: SourceLocation = #_sourceLocation
) -> T? {
    guard let value else {
        Issue.record("\(label)", sourceLocation: sourceLocation)
        return nil
    }
    return value
}

public func expectNil<T>(
    _ value: T?,
    _ label: String = "expected nil",
    sourceLocation: SourceLocation = #_sourceLocation
) {
    if let value {
        Issue.record("\(label), got \(value)", sourceLocation: sourceLocation)
    }
}

/// Explicit count assert with the collection's contents on failure. For the cases
/// where the count genuinely is the contract; a contents check (`expectEqual`) is
/// stronger when the elements are known.
public func expectCount<C: Collection>(
    _ collection: C,
    _ expected: Int,
    _ label: String = "",
    sourceLocation: SourceLocation = #_sourceLocation
) {
    if collection.count != expected {
        let prefix = label.isEmpty ? "" : "\(label): "
        Issue.record(
            "\(prefix)expected \(expected) element(s), got \(collection.count)",
            sourceLocation: sourceLocation)
    }
}

/// Identity helper that *forces* an explicit element type at the fixture boundary, so
/// a large literal array is type-checked once here (cheap, isolated) instead of
/// inside a hot inferred `#expect`. Usage: `let rows = typedFixture([Row].self) { […] }`.
public func typedFixture<T>(_ type: [T].Type = [T].self, _ build: () -> [T]) -> [T] {
    build()
}

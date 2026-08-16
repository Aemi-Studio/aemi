# Oracles & disciplined asserts

Compare against a reference model, demand the *right* error, and keep a heavy expectation
from blowing the compiler's type-check budget.

## The problem

Two recurring weaknesses in test suites:

- **Weak comparisons.** "It threw *something*" (`#expect(throws: Error.self)`) passes even
  when the code throws the wrong error for the wrong reason. Comparing two row sets with
  `==` fails spuriously when order differs or a `NaN` is involved.
- **The type-check-time flake.** A big inferred `#expect(bigChainedExpression == [literal, …])`
  forces the Swift solver to type-check the whole boolean — operands and inline literal —
  as a single constraint system. Under the `-warn-long-expression-type-checking` budget the
  AD-family builds with, one such expression *fails the build* under load. The failure is
  non-deterministic and maddening: the same code compiles on a quiet machine and times out
  on a busy one.

## The design

### Reference oracles

``ReferenceComparison`` is the shared differential comparator lifted from the SQLite-mirror
suite. ``ReferenceComparison/rowsMatch(_:_:ordered:matches:precedes:)`` compares two row
sets either ordered or as a multiset (sorted into a canonical order first), with
caller-supplied element equality — so a float column can pass a `NaN`-aware compare while
everything else uses `==`. ``ReferenceComparison/floatMatches(_:_:)`` encodes that "equal,
or both `NaN`" rule directly. On top, `expectParity(_:_:_:sourceLocation:)`,
`expectRoundTripIdentity(_:sourceLocation:via:)`, and `expectThrows(_:sourceLocation:where:)`
turn those into one-line assertions.

`expectThrows(_:sourceLocation:where:)` codifies the family's *zero-`#expect(throws: Error.self)`*
discipline: the error must be the expected concrete type **and** its payload must satisfy a
predicate. It returns the caught error for further inspection and routes every failure
(returned normally / wrong type / rejected payload) to `Issue.record`, so it never traps the
runner.

### Typed asserts that split the megaexpression

The typed *fixture* asserts — `expectEqual`, `expectNotEqual`, `expectTrue`, `expectFalse`,
`expectNil`, `expectNotNil`, `expectCount`, `typedFixture` — are plain generic functions, and
that is the whole point. Passing a value to `expectTrue(_:)` lets the operand type-check
**on its own** (fast, isolated) instead of inside the `#expect` macro's combined constraint
system. `typedFixture(_:_:)` forces an explicit element type at a fixture boundary so a large
literal array is type-checked once, cheaply, rather than re-inferred inside a hot expectation.

### Why it matters

This is dogfooded and CI-enforced: the kit's strict lane builds with
`-warn-long-expression-type-checking=100`, and that budget caught two of the kit's own
row-oracle expectations exceeding 100 ms — now rewritten onto `expectTrue`/`expectFalse`.
The asserts aren't stylistic sugar; they're the mechanism that keeps a large suite
compiling deterministically under load.

## Using it

Demand the exact error and inspect it:

```swift
let error = expectThrows({ try parser.parse(bad) }, where: { (e: ParseError) in
    if case .unexpectedToken(let t) = e { return t == .comma }
    return false
})
#expect(error?.line == 3)
```

Multiset row parity against a reference model, and a round-trip:

```swift
expectParity(rows: ours, reference, ordered: false, elementOrder: { $0.compare($1) })
expectRoundTripIdentity(node) { try decode(encode($0)) }
```

Keep a hot expectation under budget by lifting the value out of the macro:

```swift
let rows: [Row] = typedFixture { [ /* big literal */ ] }   // type-checked once, here
expectEqual(query.run(), rows)                              // each operand checks on its own
```

### When to use it

- Use `expectThrows(_:where:)` instead of `#expect(throws: Error.self)` whenever the error's
  *case or payload* is part of the contract.
- Use ``ReferenceComparison`` / `expectParity` for differential testing against a mirror,
  oracle, or second code path; pass an order-aware comparator for multiset comparison.
- Reach for the typed asserts when an `#expect` involves big literals, deep generic
  inference, or long operator chains — exactly the expressions the type-checker is slow on.

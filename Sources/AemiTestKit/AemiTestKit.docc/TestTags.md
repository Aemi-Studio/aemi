# Test tags for CI lane selection

A shared vocabulary of `Tag`s so one CI configuration can select or exclude a category of
test uniformly across all six AD-family packages.

## The problem

Different kinds of test belong in different CI lanes. Seeded fuzz and crash-injection suites
want to run under AddressSanitizer and ThreadSanitizer, where they're slow but catch the
most; a fast pre-merge lane wants to *exclude* long soak suites; a nightly lane runs
everything. If each package invents its own tag names, no single CI rule can express "run
only fuzz + parity under the sanitizers" across the family — the selection has to be
re-authored per repo, and drifts.

## The design

AemiTestKit defines the canonical tags once, as extensions on Swift Testing's `Tag`:

- `.fuzz` — seeded fuzz / crash-injection suites that prove "never trap / hang / OOM."
- `.parity` — differential-oracle suites comparing against a reference model (a SQLite
  mirror, a JS oracle, tape-vs-SAX).
- `.property` — property-based suites asserting an invariant over seeded random inputs.
- `.soak` — long-running soak / endurance suites.
- `.concurrency` — concurrency / async-coordination suites.

Every package applies the *same* names, so a CI lane's `--filter`/`--skip` rules are written
once and mean the same thing everywhere.

### Why it matters

Tags are how the kit's two pillars meet CI policy. The fuzz and concurrency suites are
exactly the ones that benefit from sanitizers (a latent out-of-bounds in a parser, a data
race in a coordination primitive), and tagging them lets the sanitizer lanes target them
without enumerating suites by hand. Shared names turn "our testing strategy" into a portable,
mechanical CI rule instead of per-repo tribal knowledge.

## Using it

Tag a suite, then select it in CI:

```swift
@Suite("Archive corruption", .tags(.fuzz))
struct ArchiveFuzzTests { /* … */ }
```

```bash
# Sanitizer lane: run only the suites worth the slowdown.
swift test --sanitize=address --filter-tag fuzz --filter-tag concurrency

# Fast pre-merge lane: everything except the slow soak suites.
swift test --skip-tag soak
```

### When to use it

- Tag every suite with the one category that describes it, using these shared names rather
  than per-package inventions.
- Drive sanitizer and nightly lanes off `.fuzz` / `.concurrency` / `.soak`; keep the fast
  lane lean by excluding `.soak`.
- If a genuinely new category emerges family-wide, add it here so every package inherits it
  at once.

---
status: accepted
date: 2026-11-06
---

# 0033 — TLA+ and Lean lexers, and what the AemiFormal report's other requests wait for

## Context

AemiFormal's report on aemi asked for nine things. ADR 0032 built the three with consumers in the family (graph kernels, big
integers, SplitMix64). This record answers the rest. The rule applied is the family's: build a kernel for a recorded gap, and
measure it on a consumer before it is kept. The family was searched for consumers of each.

## Decision

- **Q6, lexers: built.** `Language` gains `.tla` (TLA+ and PlusCal) and `.lean` (Lean 4). Both run on the shared code scanner with a
  syntax table each:
  - TLA+: `\*` line comments, nesting `(* *)` (a PlusCal algorithm inside one reads as a comment, as the TLA+ tools read it).
  - Lean: `--` line comments, nesting `/- -/` (doc comments among them), `@word` attributes, and no `'` quote, since names such as
    `h'` use it.
  - Names, aliases (`tla+`, `tlaplus`, `pluscal`, `lean4`) and the extensions `.tla` and `.lean`.

  The consumers are the family's highlighters as they stand, which find a fence's language by name or extension: MarkdownLook's
  code blocks and ask's. The family writes TLA+ specifications (AemiHMMML's and AemiMarkdown's `docs/formal`). The enum is still
  closed: an open registry would cost every scan a lookup, for languages no one has named. No `switch` over `Language` in the family
  lacks a `default`, so the new cases break no one.
- **Q5b, stability of `KeyedHash`: yes.** Its output under a given key is a contract. The tests pin SipHash-1-3 to CPython's values
  and SipHash-2-4 to OpenSSL's, so a change to the function fails them. A checkpoint that stores the key beside its hashes can rely
  on that across aemi revisions.
- **R2 (writable shared mapping), R3 (compute pool, sharded frontier), Q5 (128-bit `KeyedHash`): they belong in aemi**, in `AemiIO`,
  `AemiRuntime` and `AemiKernel`, and are not built yet. Their only consumer is AemiFormal, which has no code that would use them,
  so there is nothing to measure them on. They are built when AemiFormal's first user of each lands, against it, to this package's
  standard: exhaustive and mutation tests, guard pages for mapped memory, a TLA+ model for the pool's termination.
- **Q8, capacities: no 64-bit `Symbol` or `HashIndex` for now.** No consumer has come near `UInt32` symbols or `Int32` values.
  AemiFormal's intent, symbol numbers kept out of a state's identity and interners merged at barriers, is the one ADR 0019's
  `merge(workers:)` was built for.

## Verification

The lexers' corpus tests now run TLA+ and Lean too: a line-by-line scan equals the whole-text scan on generated corpora, every
prefix scans in bounds, and the generated-text checks cover each language's tricky pieces. Tricky lines pin the tokens: nested
comments, escaped quotes, `x'` and `h'` that start no string. A mutant that stops TLA+ comments nesting fails the tests.

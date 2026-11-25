---
status: proposed
date: 2026-10-20
---

# 0012 — Interned strings decode once and deterministically

## Context

`@Interned` expands a property into a getter that decodes on **every read**:
`get { SI.v([bytes…], key) }`. `SI._decodedBytes` builds a permutation `ContiguousArray<Int>` and an
output `ContiguousArray<UInt8>`, then `String(decoding:)` copies again.

The consumer that surfaced this is AemiSDR, which interns 58 private Core Animation / UIKit names and reads
several of them per frame (`layoutSubviews`, display-link ticks). Probe, recorded in AemiSDR's diary
2026-10-20-01: `SI` and `_SIGen` copied verbatim from `StringInterner.swift`, the getter written exactly as
the macro expands it, `swiftc -O` (Swift 6.4), 100,000 reads × 9 rounds, allocations counted with the
`malloc_logger` hook `CAemiTestKitMalloc` uses, two runs:

| Read | median | p90 | allocations/read |
|---|---|---|---|
| `@Interned`, 11-byte name | 155 ns | 196–198 ns | 2 |
| `@Interned`, 27-byte name | 255–259 ns | 308–406 ns | 3 |
| `static let x = SI.v(…)` | 0.9 ns | 0.9 ns | 0 |

The constant byte literal does not allocate under `-O`; the permutation and output arrays do, and a
name over 15 UTF-8 bytes adds the heap `String`. This is a single-module approximation of a cross-module
`@inlinable` call; the real-package number is owed.

Two further properties of the current macro, found by reading `InternedObfuscation.make`:

- **Keys are `UInt64.random` at expansion time.** Every build emits different bytes for the same source,
  so two builds of one commit are not byte-identical and a binary diff between releases is all noise.
- **The result is always `String`.** Every private-API consumer then converts it — `NSSelectorFromString`,
  `NSClassFromString`, `dlsym` — at each call site, and nothing stops a decoded name being passed where a
  different kind of name was meant.

## Decision (proposed)

1. **Decode once.** `@Interned` on a `static` property emits a peer `private static let` holding the
   decoded value (lazy, thread-safe initialisation by the language) and a getter that returns it. Instance
   and local uses keep the current expansion; `#Interned(…)` is unchanged. The string is still absent from
   the binary, which is the property the macro exists for; it is present in memory once, as it already was
   transiently on every read.
2. **Deterministic keys.** Derive each key from a keyed hash of (module, file, line, column, literal) with
   a per-package secret supplied at build time, defaulting to a fixed seed. Same source, same bytes.
3. **Typed forms are not InternedStrings' job.** An earlier draft proposed `#InternedSelector`, `#InternedClass` and
   `#InternedSymbol` here. The owner's direction is that InternedStrings stays the easiest way to *hold* a name, and that
   loading private classes, methods and properties by their expected types lives in a package that relies on it: **Abysm**
   (`Developer/ongoing/swift/Abysm`), which re-exports InternedStrings and verifies each call's signature against the
   runtime. InternedStrings' part is (1), (2) and (4).
4. **A cheaper decoder** only after (1), and only if measured: a permutation computed index-by-index
   (a bijection such as an affine map mod n) needs no permutation buffer; `String(unsafeUninitializedCapacity:)`
   writes the output once. This changes the encoding, so macro and runtime move in one commit.

## Consequences

- The generic private-symbol resolver this ADR first expected to host (lookup, owning image, type encoding, typed call)
  exists as Abysm, measured and tested on macOS, iOS 18.6 and iOS 27.0; see its ADR-0001 for the comparison with
  Dynamic and ABIBridge. Abysm's hot paths are better served by (1): a decoded name is read once, at resolution.
- The standalone `g-cqd/InternedStrings` repository is a forwarding shim (`@_exported import InternedStrings`
  from this package). It needs no code change; its CI (two legs, 1 h 17 min on 2026-09-16, `swift package
  update` against `branch: main`) should either pin this package by revision or be retired in favour of
  this package's own tests.
- Every probe above is re-run through the real package, with `expectAllocations`, before (1) lands; the
  ceiling for a cached read is zero allocations, as a test.

---
status: accepted
date: 2026-11-06
---

# 0032 — Graph kernels, big integers and a shipped SplitMix64

## Context

AemiFormal's report on aemi (its `docs/research/aemi-upstream-report-2026-11.md`) asked for graph kernels (R1), big integers (R4)
and a SplitMix64 outside the test kit (Q7). The family was searched for code each would replace or serve; only these three have
a consumer today besides AemiFormal:

| Request | Consumers in the family |
|---|---|
| Strongly connected components, disjoint sets | arcleak's `StronglyConnectedComponents` (cycle detection), dolly's recursive `UnionFind` (clone groups) |
| Big integers | AemiHMMML's YAML integers past 64 bits (kept as text today), AemiJSON's integers past 64 bits, AemiFormal |
| SplitMix64 | dolly's `splitMix64` (MinHash seeds), AemiHMMML's differential tool, `AemiTestKit.SeededRNG`, AemiFormal |

The writable shared mapping (R2), the compute pool (R3), a 128-bit hash (Q5), lexers (Q6) and 64-bit capacities (Q8) have no
consumer but AemiFormal, so they wait until it uses them and their gain can be measured.

## Decision

In `AemiKernel`, Foundation-free:

- **`SplitMix64`**: the published stream and its finalizer (`mix`). `SeededRNG` draws from it, so a seed gives the same sequence in
  both, and every pinned test corpus is unchanged.
- **`StronglyConnectedComponents.find(in:)`** over a `Digraph` (node count, successors by position), so a graph too large to hold is
  read on demand; `[[Int]]` conforms. Tarjan's algorithm, iterative, components in completion order. A first version that copied
  each node's successors into its frame cost arcleak 0.4 % more instructions, so a frame holds a position only.
- **`DisjointSets`**: union by rank (ties go to the first root, as dolly's did), path halving, `find` a loop.
- **`BigInt`**: sign and 64-bit limbs; parsing and printing in radix 2 to 36 a chunk of digits at a time; addition, subtraction,
  schoolbook multiplication, Knuth's algorithm D for division (truncating, as Swift's integers do); powers by squaring; exact
  conversions to `Int64` and `UInt64`.

## Verification

- SCC against a reachability reference on 300 generated graphs (also checking completion order), and a chain and a ring of a
  million nodes. Disjoint sets against a naive labelling, and a million chained unions.
- `BigInt` against `Int128` on 5,000 cases; `q·b + r = a` with `|r| < |b|` on 3,000 many-limb cases built to hit carries; round trips
  in five radixes; and, once, 2,000 random operations up to 1,500 bits against Python's integers, all agreeing. A mutant that skips
  algorithm D's add-back step failed 194 checks.
- Consumers, before and after, the same aemi otherwise: arcleak on a 20,000-type ownership ring, 9.577G against 9.575G instructions,
  output byte for byte the same; dolly on AemiHMMML's sources, 1.400G against 1.400G, the same findings, and its MinHash,
  prefix-index and embedding tests pass.

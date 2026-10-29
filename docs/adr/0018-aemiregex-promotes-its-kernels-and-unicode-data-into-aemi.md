---
status: accepted
date: 2026-10-29
---

# 0018 — AemiRegex's kernels, UTF-8 reading and Unicode data are promoted into aemi, and AemiRegex depends on aemi

## Context

AemiRegex had no package dependencies by design, so it carried its own copies of what aemi is for: byte scans (a single byte, a pair,
a small set), a two-byte Teddy kernel in C, strict UTF-8 reading forward and backward, a bounds-checked byte view, a byte bitmap, a
sparse set, a scratch pool, scalar-range-to-UTF-8 compilation, and generated Unicode tables (general categories, scripts, script
extensions, binary properties, simple case folding) with a range-set type. Some duplicated aemi (memchr, a nibble-table set scan); the
rest was general and had, or was about to have, other users (AemiMarkdown classifies Unicode punctuation from the platform's data). The
owner asked for the whole of it to be consolidated into aemi, AemiRegex to depend on aemi as a member of the same family, and every
change to be driven by tests seen failing first.

## Decision

| From AemiRegex | To | Notes |
|---|---|---|
| `teddy.c` (`aemire_teddy2_*`) | CAemiKernels `adf_teddy.c` (`adf_pair_set_*`), AemiKernels `PairSet` | aemi's CPU check (`adf_kernels_isa`) replaces `__builtin_cpu_supports`; passes aemi's strict C flags on arm64 and x86-64 |
| pair scan (Swift SIMD) | AemiKernels `firstIndex(ofPair:_:in:from:)` | inlinable |
| small-set scan (Swift SIMD compares) | AemiKernels `SmallByteSet` | inlinable; kept beside the C nibble-table kernel, which it beats where a scan is called once per candidate over short spans |
| single-byte scan | AemiKernels `firstIndexOfByte` (memchr) | replaced, no promotion |
| `Utf8.width`, `ScalarReader` | AemiKernel `UTF8Scalar` | strict, beside the lenient `UTF8Decode` |
| `ByteBuffer` | AemiKernel `CheckedBytes` | a `RandomAccessCollection`; inlinable |
| `ByteSet` (256-bit) | AemiKernel `ByteBitmap` | inlinable |
| `SparseSet` | AemiKernel `SparseSet` | inlinable |
| `Utf8Sequences` | AemiKernel `UTF8RangeSequences` | ranges are `ClosedRange<UInt8>` |
| `ScratchPool`, `ScratchBox` | AemiRuntime `ScratchPool<Value>` | inlinable; the box's `value` has unchecked exclusivity (below) |
| `ScalarSet` (+ algebra, folding closure) | AemiUnicode `UnicodeScalarSet` | `simpleCaseClosure()` |
| generated tables, `UnicodeFolding` | AemiUnicode `UnicodeData`, `CaseFolding.simpleOrbit(of:)`, `simpleOrbits` | exact names only; Go's loose names, PCRE2's spelling and the special names stay in AemiRegex |
| `Scripts/unicode/gen.go`, `gen-properties.js`, `teddy-check` | `scripts/unicode/`, `scripts/pair-set-check.{c,sh}` | CI regenerates the Go table and diffs it (`unicode-tables` job) |

## Tests, red first

The implementation was moved before its aemi tests existed, so red was shown after the fact, twice over:

- **Missing**: with every new implementation file set aside and the header reverted, each new test target (AemiKernelsTests,
  AemiKernelTests, AemiRuntimeTests, AemiUnicodeTests) fails to build; restored, they pass.
- **Wrong**: one plausible bug injected per component, each turning its tests red: overlong UTF-8 leads accepted; surrogates not split
  out of a range; the Teddy NEON second load at the wrong offset; the Teddy 64-byte loop and the pair scan reading one byte past the
  end; a wrong bit in the bitmap; sparse-set membership ignoring the dense array; the pool never returning a value; adjacent ranges not
  merged; `C` without `Cn`; the orbit search missing the last entry; `SmallByteSet` reading past the end. `CheckedBytes` without
  its check is red only in release: in debug, `UnsafeBufferPointer` traps on its own.
- `SmallByteSet` (new API) was written test first: red without it, green with it.
- The kernel's x86-64 path: `scripts/pair-set-check.sh` under Rosetta (which reports SSE4.2, so the SSSE3 code runs) and on arm64,
  104,830 checks each with ASan and UBSan, SIMD equal to scalar.
- Ported: AemiRegex's Teddy and pair tests, `CheckedBytes`' exit tests, and its table tests (version, agreement with the standard
  library for every character assigned before Unicode 15, groups, scripts, orbits). New: `UTF8Scalar` against the standard library's
  strict decoder (every one- and two-byte sequence, sampled three- and four-byte ones), `UTF8RangeSequences` against the standard
  library's encoder, set algebra against `Set` arithmetic, script extensions, binary properties.
- AemiRegex's own suite, the conformance check (golden tests against Go, differential, PCRE2 oracle fixtures): 170 tests pass; the 7
  table tests now live here.

## Speed

AemiRegex's workloads over its own sources copied 20 times (18 MB), median of 15 rounds, three interleaved runs of each build, release,
loaded machine; µs, match counts identical in every row:

```
workload             mode   before µs   after µs  ratio  counts
literal              files        944        762   0.81  same
literal              one          687        564   0.82  same
alternation          files       1771       1719   0.97  same
alternation          one         1558       1540   0.99  same
func-async           files       1537       1526   0.99  same
func-async           one         1343       1332   0.99  same
captures             files       1869       1030   0.55  same
captures             one         1625        888   0.55  same
case-insensitive     files       1292       1260   0.98  same
case-insensitive     one         1535       1439   0.94  same
no-match-rare-byte   files        771        479   0.62  same
no-match-rare-byte   one          498        240   0.48  same
word-boundary        files        888        883   0.99  same
word-boundary        one          674        672   1.00  same
line-anchor          files        824        807   0.98  same
line-anchor          one          612        611   1.00  same
prefix-nullable      files      11286      11135   0.99  same
prefix-nullable      one        11179      11036   0.99  same
blank-lines          files      23895      23442   0.98  same
blank-lines          one        23669      23243   0.98  same
optional-word        files     178221     170747   0.96  same
optional-word        one       182973     170509   0.93  same
trailing-space       files        181        176   0.97  same
trailing-space       one            0          0   0.00  same
empty-word-edges     files     144102     142551   0.99  same
empty-word-edges     one       147962     145908   0.99  same
empty-line-ends      files      30964      31068   1.00  same
empty-line-ends      one        30675      31024   1.01  same
```

Two findings on the way, both about calling into another module:

- An unspecialized `ScratchPool<SearchScratch>` looked up generic metadata on every search (profiled: `swift_getGenericMetadata`,
  `getCache`): about 0.45 µs a search, up to 3.4x on short files. Inlinable, it specializes in the caller.
- The pool's box, now in another module, paid a run-time exclusivity check (`swift_beginAccess`) on each search, which the pool's lock
  already makes redundant: `@exclusivity(unchecked)` on that one property, with the rule written beside it.
- The C nibble-table set scan was 13% slower than the inline compare loop for a set of frequent letters, called once per candidate:
  both are kept, the caller chooses.

## Consequences

- AemiRegex joins the pin chain: an aemi revision is adopted by AemiRegex first, then AemiJSON and AemiMarkdown, then TerminalKit, ask
  and Atelier.
- The binary-property table stays at Unicode 17: regenerating it with today's node gives Unicode 18, which would not match the Go-sourced
  categories. Both move together when Go's `unicode` does.
- Not done: Linux (nothing here was built for it), and Swift 6.3 for these files (6.3.3 was verified for AemiIO only).

---
status: accepted
date: 2026-11-05
---

# 0031 — The primitives the format parsers kept re-implementing

## Context

Issue #5, from AemiHMMML's TOML parser (profiled with `sample`, measured with ordo-one): AemiJSON, AemiMarkdown and AemiHMMML each
carried private copies of the same byte-level work, and AemiHMMML's profile showed where the copies cost time. The owner asked for
all of it in aemi, with SIMD kernels where a byte scan benefits, and the consumers moved onto it.

## Decision

| Item | What | Where |
|---|---|---|
| Keyed hash | `KeyedHash`: SipHash-1-3 (and 2-4, for checking) under a 128-bit key, inlined, eight bytes a step; `.process` is random per process, zero under `SWIFT_DETERMINISTIC_HASHING`; `hash(tweak:_:)` scopes a key to a table | AemiKernel |
| Keyed interner | `Interner(hashing: .keyed(…))`: the same symbols; `.fast` (unseeded `WyHash`) stays the default for keys the program chose; merged interners must share their hashing | AemiInterner |
| Hash index | `HashIndex`: open addressing of `Int32` values with stored 64-bit hashes; keys stay where the caller keeps them, equality is the caller's | AemiKernel |
| Ranged, safe scans | `ByteScan`: `firstIndexOfAny`, `firstIndex(of:)`, `indexOfControlOrAny`, `firstIndex(inSet:)`, `firstIndex(notInSet:)`, `firstIndexNotEither`, `firstInvalidUTF8` over `[UInt8]` (and `ContiguousArray`) with `from:to:` and absolute indices; consumers hold no pointer | AemiKernel |
| Short-run front | the first 32 bytes searched with SWAR before a kernel call | `ByteScan` |
| Exact SWAR lanes | `SWAR.nonZeroLanes`, `equalLanes`, `neitherLanes`: exact in every lane (no borrow crosses lanes) | AemiKernel |
| Complement set scan | `adf_index_not_in_set` (NEON `tbl` + `cmeq #0`, SSSE3 `pshufb`), `AemiKernels.firstIndex(notInSet:)` | CAemiKernels |
| Bulk positions | `adf_positions_of_either` (NEON 64-byte blocks, AVX2, SSE2): every offset of either of two bytes written into room the caller gives, resumable; `AemiKernels.appendPositions` | CAemiKernels |
| Decimals | `DecimalScanner` / `DecimalLiteral`: sign, digits, point, exponent and an optional separator in one pass, eight digits at a time with SWAR (simdjson's method), padded zeros free; `DecimalFloat.double(_:in:)`: Clinger, Eisel-Lemire, then `LongDecimal` (768 digits and a sticky one) for `Double(String)`. Promoted from AemiJSON | AemiKernel |
| Dates and times | `RFC3339DateTime` with `Syntax` options (TOML's local forms, a space separator, optional seconds), ranges checked, `unixSeconds` | AemiKernel |
| Line index | `LineIndex` over bytes with LF/CRLF or also lone CR breaks, built by the positions kernel; line and column (scalars and bytes) on demand | AemiText |

The C kernels follow ADR 0027: each has a scalar reference, joins `kernels_exhaustive.c` (every byte at every position, guard
pages; positions at every density with every output size around the vector steps, resumed), `kernels_fuzz.c`, `codec_threads.c`
and the guard-page Swift tests, and has mutants in `Scripts/mutants/kernels.txt` that its check kills.

Not taken: a "linked arena to child list" utility beside `TapeSlot` (issue item 10) waits for YAML to show it is needed.

## Evidence (2026-11-05, 8-core M3, machine load 7 to 16; ordo-one wall clock p50, `parse/*` in the suite)

| | before | after |
|---|---|---|
| hash 4,096 short keys | `Hasher` 122 µs | `KeyedHash` 55 µs (`WyHash`, unkeyed: 17) |
| a tokenizer's stops, one search at a time | kernel call 550 µs | `ByteScan` 314 µs |
| line starts of 300 KB | `memchr` per line 159 µs | `LineIndex` 84 µs |
| 20,000 coordinates | `Double(String)` 5.5 ms | `DecimalScanner` + `DecimalFloat` 2.8 ms; 0.46 ms against 1.49 after the change below |
| indentation of 4 to 8 spaces | byte loop 191 µs | SWAR 216 µs at p50, 165 at p25: no clear gain at that length |
| interning 4,096 short keys | fast 370 µs | keyed 410 µs |

Checks: SipHash-2-4 against OpenSSL 3.5.9 and SipHash-1-3 against CPython (`PYTHONHASHSEED=0`); decimals against `Double(String)`
and `Int64(String)` on 40,000 generated literals and the 768-digit tie; dates against the C date kernel on every day of 1890 to
2110; `kernels-check.sh` (native NEON, SSE4.2 and AVX2 under Rosetta, threads under ThreadSanitizer), 60 s of libFuzzer per
backend, and the five new mutants all killed.

## Amendment (same day): the decimal scanner's fast pass

On AemiHMMML's numeric benchmark (canada.toml) the first version made parsing slower than the fused reader it replaced (51
instructions per byte against 42): every digit went through the zero-aware bookkeeping, and a failed eight-digit word was retried
before each remaining digit. Now, as AemiJSON's `scanDecimal`: one tight pass counts every digit when a number has at most nineteen
(nearly all), converting a word's leading digits at once (all eight, or the run's last one to seven, shifted into place behind
ASCII zeros, found by an exact per-lane digit test); the zero-aware pass runs only past nineteen. `sample` on the parse: the digit
loop went from 2,392 samples to 517.

## Amendment (same day): parity with AemiJSON's own number scan

Moving AemiJSON onto the scanner first cost its canada.json value tree 14 % more instructions. A micro-benchmark of canada's
111,126 numbers against AemiJSON's original `scanDecimal` (copied beside it) led to: a literal of six words instead of fourteen
fields (flags as bits, counts as 32-bit), built in place and returned once; the fast pass inlinable, the precise pass out of line;
the run left at the end of an exact-length buffer read with one load of the eight bytes ending there (the overlapping tail of
aemi's NEON scans); the first three integer digits read one by one, since a word costs more than the bytes for the integer part
of most numbers; and no trailing-zero retry in `fastDouble` (Eisel-Lemire handles those; the `Float` path keeps it). Per number:
320 instructions and 17 ns against the original's 320 and 18 ns; scanning alone 232 and 8 ns against 259 and 11. AemiJSON's
probe, normalised by Foundation's time in the same run (the machine's load varied): every workload within ±3 %, memory the same
or lower.

## Consequences

How the consolidation landed (2026-11-05), each measured before it was kept:

| Consumer | What moved onto these primitives | Measured |
|---|---|---|
| AemiHMMML (TOML) | its ByteScan, LineIndex, key table and hashing, date parser and float reader (all deleted there) | canada.toml 36 instructions per byte against 42 with its own copies; cargo-lock 38 against 40; twitter 50 against 52 |
| AemiJSON 416b2da | `scanDecimal`, `scanPaddedDecimal`, `LongDecimal` (deleted); duplicate keys hashed with `KeyedHash` | AemiJSONProbe normalised by Foundation's time in the same run: every workload within ±3 %, memory the same or lower |
| CSVCoder a7604ed | `SWARUtils`' predicates are `SWAR.equals` and `SWAR.equalLanes` | the same arithmetic |
| AemiMarkdown | nothing, by measurement: with these scans `@inlinable`, its `ByteScan` moved onto them runs the 998-document corpus at the same instructions per byte but 4 to 5 % slower on the largest documents (code layout: the control, its own wrapper on the same aemi, matches the old tree), and the UTF-8 and control check alone about 1 % slower. Its wrapper is thirty lines over the same kernels, so it stays | |
| AemiProtobuf | nothing: protobuf's `Timestamp` text is stricter than RFC 3339 (uppercase `T` and `Z` only, no leap second, one to nine fraction digits), and its conformance suite checks those refusals | |

The family's graph moved to one aemi revision, leaves first (ADR 0030): AemiRegex af5a281, AemiJSON 416b2da, AemiProtobuf
49fe950, AemiMermaid 1445545, AemiMarkdown 3ac680f, TerminalKit 0297446, ask 7f3ef750, AemiHMMML 7c39b56. analyzerkit, the
analyzers, HTTP, litmus and swift-search stay on their own graph (aemi b31f499): none of them duplicates these primitives, and
their interner keys are trusted, so `.fast` stays right for them.

Function merging. Swift's optimizer folds functions whose IR differs only in constants or callees into one shared body behind
thunks (symbols ending `Tm`). `firstIndex(notInSet:base:count:)`, added here, differed from `firstIndex(inSet:base:count:)`
only in the C function called, and the merge cost the set scan, AemiMarkdown's hot path, 23 % more instructions per byte (5.58
to 6.86 over the corpus; 1.4 % on the whole parse), with the C code unchanged. Reordering the closures did not stop it; a clamp
of the result (one conditional select) gives the body a shape of its own, and the scan is back at 5.58. Check `nm … | grep Tm`
when a pair of near-identical entry points is added. `ByteScan`'s set scans and UTF-8 check are now `@inlinable`, so a caller
inlines them rather than calling the merged out-of-line copy.

- `Interner` gains a parameter with a default, so existing callers are unchanged.

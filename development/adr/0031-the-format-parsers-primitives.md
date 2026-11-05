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
| 20,000 coordinates | `Double(String)` 5.5 ms | `DecimalScanner` + `DecimalFloat` 2.8 ms |
| indentation of 4 to 8 spaces | byte loop 191 µs | SWAR 216 µs at p50, 165 at p25: no clear gain at that length |
| interning 4,096 short keys | fast 370 µs | keyed 410 µs |

Checks: SipHash-2-4 against OpenSSL 3.5.9 and SipHash-1-3 against CPython (`PYTHONHASHSEED=0`); decimals against `Double(String)`
and `Int64(String)` on 40,000 generated literals and the 768-digit tie; dates against the C date kernel on every day of 1890 to
2110; `kernels-check.sh` (native NEON, SSE4.2 and AVX2 under Rosetta, threads under ThreadSanitizer), 60 s of libFuzzer per
backend, and the five new mutants all killed.

## Consequences

- AemiHMMML's `ByteScan`, `LineIndex`, key hashing and date parsing, AemiMarkdown's `ByteScan`, and AemiJSON's `scanDecimal`,
  `LongDecimal` and duplicate-key hashing move onto these; the consumers repin together (ADR 0030).
- `Interner` gains a parameter with a default, so existing callers are unchanged.

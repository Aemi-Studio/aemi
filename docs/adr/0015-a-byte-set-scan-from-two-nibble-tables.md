---
status: accepted
date: 2026-10-25
---

# 0015 — A scan for any byte of a set, from two nibble tables

## Context

A tokenizer stops at a set of bytes that `index_of_any5` cannot hold: Markdown's inline scanner stops at eleven (`\n \ ` * _ ~ [ ] ! < &`), and the same tokenizer's block-level
control-byte check stops at the C0 controls except tab, line feed and carriage return, and DEL. AemiMarkdown scanned plain text one byte at a time through a table
(about 30 ns for an 80-byte line in C, measured as the scalar reference of this kernel).

## Decision

- `adf_index_of_set(buf, len, lo[16], hi[16])`: the first byte `b` with `lo[b & 15] & hi[b >> 4] != 0`. On arm64 each table is one `tbl` lookup and the loop is
  `adf_neon_scan.h` (ADR-0014: 64 bytes a step, overlapping tail, hit located from the mask). On x86-64 with SSE4.2 (which implies SSSE3) `pshufb` does it with a
  16-byte loop; elsewhere the scalar reference runs. The x86-64 kernel was checked under Rosetta (differential check, 0 mismatches) and not timed.
- `AemiKernels.ByteSet` builds the tables from a set of bytes. The tables are exact for a set whose upper nibbles show at most eight distinct rows (the lower nibbles that
  occur with one upper nibble), each row one bit; `init?` returns nil for any other set, so a set is never approximated. Markdown's eleven bytes are six rows.
- `AemiKernels.firstIndex(inSet:base:count:backend:)` and an array form. `.scalar` forces the reference loop.

## Measured

`scripts/bench-c-kernels.sh --small`, interleaved, median and p10 to p90, M2 Pro, `-Os`. The machine was heavily loaded (load average 52), which widens the spread of the
reference column; the kernel's p10 is the steady figure. "Before" is the scalar reference with the same tables.

| Input | Scalar reference, ns (p10–p90) | Kernel, ns (p10–p90) | Ratio |
|---|---|---|---|
| 64 bytes, no hit | 40.9 (25.8–245.5) | 3.1 (3.1–11.9) | 13x |
| 80 bytes, no hit | 33.0 (32.8–220.0) | 3.7 (3.7–5.5) | 8.9x |
| 80 bytes, random hit | 26.5 (24.8–266.5) | 3.7 (3.7–82.9) | 7.2x |
| 255 bytes, no hit | 164.3 (114.9–447.5) | 13.4 (8.8–33.2) | 12x |

## Checks

- `--check` gained the kernel among its scanners (every length 0 to 300, ten alignments, every position of the first hit and a second hit after it, on exact-size
  allocations under ASan and UBSan) and a random-set check; changing the upper-nibble shift made it report mismatches, so it can fail.
- `AemiKernelsByteSetTests`: the tables hold a fitting set exactly for all 256 byte values; nine rows are refused; every backend finds the first byte at 16 lengths.

## Found on the way, not fixed here

`CAemiKernels` does not compile for x86-64 macOS under its own strict C settings: `adf_sysctl_flag` in `adf_cpu.c` is unused there and `-Werror` makes that an error.

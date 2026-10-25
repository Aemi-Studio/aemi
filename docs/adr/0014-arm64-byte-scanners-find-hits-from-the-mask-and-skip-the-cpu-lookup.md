---
status: accepted
date: 2026-10-25
---

# 0014 — The arm64 byte scanners find a hit from the compare mask, end with an overlapping load, and skip the per-call CPU lookup

## Context

ADR-0011 measured that the dispatched scanners lose about half their speed at 64 bytes. A consumer that scans one line at a time (ask's Markdown
parser, roadmap 0065) lives at 64 to 255 bytes, so that regime is the one that matters to it. Reading `adf_scan.c` and `adf_cpu.c` gave three
suspects, each a cost that does not shrink with the input:

1. every dispatched call ran `adf_kernels_isa()`, which calls `pthread_once`, then a `switch` whose three arm64 cases all led to the same kernel;
2. the NEON kernels found a hit by rescanning its 16 bytes with a scalar loop;
3. an input that is not a multiple of 16 ended with a scalar loop of up to 15 bytes.

## Probes

`scripts/bench-c-kernels.sh --small`, new: nanoseconds per call, with the previous `adf_scan.c` (`SMALL_BASE=afc1be3`) compiled under other names
in the same binary; 31 interleaved rounds in a shuffled order; median and p10–p90. Two inputs per length: no hit, and a hit at a random position
(one input in eight has none) in each of 256 buffers, cycled, so the branch predictor cannot learn a position. Apple M2 Pro class machine, `-Os`
as SwiftPM builds it.

- **The harness can fail, and is not biased.** Before any change, "before" and "after" were the same code: the ratios were 0.61 to 1.12 at a load
  average of 24 to 28, the spread of noise (and one family, `string_stop` with random hits, 0.61 to 0.90, is the worst of it). A second control
  that did not change code, `fold_ascii` at 64 bytes, moved from 12.4 to 10.0 GB/s between two runs. Effects below about 25 % at 64 bytes are not
  claimed.
- **The check can fail.** `scripts/bench-c-kernels.sh --check` gained the five scanners: every length 0 to 300, ten alignments, every position of
  the first hit and a second hit after it, on exact-size allocations under AddressSanitizer and UBSan. Mutating `any5_neon_impl` to return one
  too many from its tail gave 3 mismatches at length 1; letting its loop read one byte past the input gave `heap-buffer-overflow`; both were
  reverted. (The older `check_scan` allocates one slack byte, so it could not have caught the second.)
- **Not separated:** how much of the gain is the dispatch and how much the kernel. The change made all three together.
- **A defect the first version had, caught by `AemiKernelsTests`, not by this harness:** the disallowed-text classifier marked bytes of 0x80 and over
  when `min_allowed` was above 0x80 (the old rescan had filtered them). `check_parameters` now draws random parameters; with the fix removed it
  reports `first_disallowed_text ... min 145`; with the fix it passes. The fix costs about 0.4 ns at 80 bytes (4.6 to 5.1 ns).

## Decision

- One skeleton, `adf_neon_scan.h`, for the five arm64 scanners (`any5`, `control_or_any5`, `nonascii`, `string_stop`, `first_disallowed_text`):
  each supplies only a classifier that marks the stopping bytes in a vector, and a scalar reference for inputs under 8 bytes.
- A hit is located by narrowing the compare mask to 4 bits per lane (`vshrn`) and counting trailing zeros. There is no rescan.
- The end of the input is one more 16-byte load that ends on the last byte. It overlaps bytes already scanned, which held no hit, so its first
  set lane is new. Inputs of 8 to 15 bytes are two overlapping 8-byte loads in one vector. Under 8 bytes is scalar.
- The main loop tests 64 bytes per iteration with one reduction.
- On arm64 the five dispatchers call the NEON kernel directly. NEON is mandatory on arm64, and every tier above it (`ADF_ISA_ARM_DOTPROD`,
  `ADF_ISA_ARM_I8MM`) already ran the same kernel, so nothing is lost. `adf_kernels_isa()` remains for x86-64 and for reporting.
- The named backends (`_scalar`, `_neon`), and the x86-64 kernels, are unchanged.

## Measured (p50, ns per call; before is `afc1be3`)

| Kernel | Bytes | Input | Before, ns (p10–p90) | After, ns (p10–p90) | Ratio |
|---|---|---|---|---|---|
| `index_of_any5` | 16 | no hit | 6.13 (4.75–9.29) | 2.47 (2.45–3.53) | 2.48× |
| `index_of_any5` | 16 | random hit | 12.00 (9.80–18.80) | 3.57 (3.12–6.28) | 3.36× |
| `index_of_any5` | 79 | no hit | 18.15 (17.50–24.39) | 4.91 (4.90–7.16) | 3.70× |
| `index_of_any5` | 79 | random hit | 13.18 (12.05–19.41) | 4.80 (4.60–7.87) | 2.75× |
| `index_of_any5` | 80 | no hit | 9.97 (8.91–15.33) | 5.13 (4.91–8.60) | 1.94× |
| `index_of_any5` | 80 | random hit | 12.45 (10.81–18.51) | 4.67 (4.57–13.02) | 2.67× |
| `index_of_any5` | 255 | no hit | 29.45 (26.90–36.49) | 14.09 (13.51–22.24) | 2.09× |
| `index_of_any5` | 255 | random hit | 19.74 (18.22–31.94) | 11.16 (9.67–23.54) | 1.77× |
| `index_of_control_or_any5` | 16 | no hit | 4.96 (4.91–9.91) | 2.78 (2.76–5.39) | 1.78× |
| `index_of_control_or_any5` | 16 | random hit | 12.19 (10.68–22.74) | 3.17 (2.92–7.62) | 3.84× |
| `index_of_control_or_any5` | 79 | no hit | 24.28 (21.14–36.80) | 5.89 (5.68–9.87) | 4.12× |
| `index_of_control_or_any5` | 79 | random hit | 16.38 (13.77–23.44) | 6.37 (5.30–10.48) | 2.57× |
| `index_of_control_or_any5` | 80 | no hit | 9.28 (8.92–15.23) | 6.13 (5.84–9.30) | 1.51× |
| `index_of_control_or_any5` | 80 | random hit | 13.30 (12.82–21.84) | 5.57 (5.30–10.27) | 2.39× |
| `index_of_control_or_any5` | 255 | no hit | 32.36 (32.23–37.13) | 16.19 (16.07–19.22) | 2.00× |
| `index_of_control_or_any5` | 255 | random hit | 21.46 (20.21–27.19) | 11.25 (10.94–13.80) | 1.91× |
| `index_of_nonascii` | 16 | no hit | 4.92 (4.90–5.63) | 2.46 (2.45–3.28) | 2.00× |
| `index_of_nonascii` | 16 | random hit | 7.62 (7.49–8.59) | 3.36 (3.35–3.81) | 2.26× |
| `index_of_nonascii` | 79 | no hit | 13.31 (12.32–49.89) | 2.80 (2.76–22.86) | 4.75× |
| `index_of_nonascii` | 79 | random hit | 16.17 (9.70–51.90) | 4.58 (3.54–17.35) | 3.53× |
| `index_of_nonascii` | 80 | no hit | 8.02 (7.97–29.14) | 3.09 (3.07–29.01) | 2.59× |
| `index_of_nonascii` | 80 | random hit | 9.45 (8.98–43.40) | 3.49 (3.45–7.95) | 2.71× |
| `index_of_nonascii` | 255 | no hit | 19.45 (19.09–24.52) | 7.64 (7.60–12.44) | 2.54× |
| `index_of_nonascii` | 255 | random hit | 14.58 (13.87–24.23) | 5.45 (5.41–8.57) | 2.68× |
| `index_of_string_stop` | 16 | no hit | 4.92 (4.91–6.01) | 2.76 (2.76–2.88) | 1.78× |
| `index_of_string_stop` | 16 | random hit | 8.77 (8.40–10.61) | 3.33 (3.26–3.68) | 2.63× |
| `index_of_string_stop` | 79 | no hit | 28.77 (16.88–42.98) | 8.53 (4.32–14.99) | 3.37× |
| `index_of_string_stop` | 79 | random hit | 10.95 (10.63–22.86) | 4.19 (4.16–7.39) | 2.61× |
| `index_of_string_stop` | 80 | no hit | 9.46 (9.22–17.72) | 4.92 (4.60–11.46) | 1.92× |
| `index_of_string_stop` | 80 | random hit | 11.54 (9.93–31.55) | 4.18 (4.11–12.84) | 2.76× |
| `index_of_string_stop` | 255 | no hit | 32.42 (22.90–81.34) | 14.48 (11.38–33.27) | 2.24× |
| `index_of_string_stop` | 255 | random hit | 24.06 (15.55–30.64) | 8.20 (7.75–15.70) | 2.93× |
| `first_disallowed_text` | 16 | no hit | 5.24 (5.19–6.40) | 2.78 (2.76–3.42) | 1.89× |
| `first_disallowed_text` | 16 | random hit | 11.00 (10.94–11.26) | 2.83 (2.81–2.87) | 3.89× |
| `first_disallowed_text` | 79 | no hit | 21.74 (21.41–25.74) | 4.92 (4.90–5.32) | 4.42× |
| `first_disallowed_text` | 79 | random hit | 13.96 (13.65–14.83) | 4.30 (4.24–5.11) | 3.25× |
| `first_disallowed_text` | 80 | no hit | 9.70 (9.50–9.99) | 5.06 (5.05–5.16) | 1.92× |
| `first_disallowed_text` | 80 | random hit | 13.71 (12.98–17.72) | 4.28 (4.21–6.04) | 3.21× |
| `first_disallowed_text` | 255 | no hit | 31.79 (31.42–37.88) | 13.35 (13.28–16.03) | 2.38× |
| `first_disallowed_text` | 255 | random hit | 24.53 (21.61–32.82) | 9.79 (9.18–14.81) | 2.50× |

At 64 KiB and 1 MiB, `index_of_nonascii` rose from 25.7 and 20.0 GB/s (dispatcher) to 86.8 and 83.0 GB/s, from the 64-byte unroll. `fold_ascii`, whose
code did not change, read 50.0 and 50.2 GB/s at 64 KiB.

## Consequences

- At 80 bytes the five scanners take 1.5 to 2.6 times less time with no hit and 2.4 to 3.2 times less with a hit; at 79 bytes, 3.4 to 4.8 times less
  with no hit, because the scalar tail is gone. A scan of 80 bytes is now 3 to 6 ns, call included.
- **Not measured:** x86-64 (no change was made there, and the `pthread_once` per call remains on that path); `index_of_byte`, which is `memchr`; Linux arm64.
- Follow-up, not done: a **set scan** (a byte table by two `vqtbl1q_u8` lookups, any set of up to eight classes) for tokenisers whose special bytes
  number more than five; ask's Markdown inline scanner needs it (about eleven bytes).

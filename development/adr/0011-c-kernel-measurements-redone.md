---
status: accepted
date: 2026-10-18
supersedes: the performance sections of 0008 and the figures in commit 3e64286
---

# 0011 — The C kernel measurements, redone with a harness that can fail

## Context

ADR-0008 and commit `3e64286` reported kernel speedups from ad-hoc probes that later proved flawed:
an inlined scalar reference had its stores deleted, minima were reported as medians, synchronization
used non-atomic `volatile`, and the probe could read out of bounds. Both also assumed Aemi compiles
its C at `-O2`.

## Method

`scripts/bench-c-kernels.sh` builds `Benchmarks/CKernels`:

- Kernels compile with the target's real release flags: **`-Os`**, read from SwiftPM's response file
  for `adf_fold.c`, plus `strictCSettings` parsed from `Package.swift`.
- Each variant lives in its own translation unit behind a function pointer; outputs are consumed.
- Baselines are the scalar references at `-Os`, `-O2`, and `-O2 -fno-vectorize -fno-slp-vectorize`;
  the previous NEON fold is rebuilt from `3e64286^`.
- `--check` runs every variant against the scalar reference under AddressSanitizer and UBSan over
  lengths 0–300 at 64 alignments with exact-size allocations: 0 mismatches. Control: mutating the
  previous kernel to read past its buffer is caught as a 16-byte heap-buffer-overflow.
- 31 interleaved samples per variant in shuffled order, each at least 2 ms; median and p10–p90.

Apple M2 Pro, Apple clang 21, load average about 3–4 from other work, two runs within a few percent
except at 8 MiB, where p10 falls to 15–24 GB/s.

## Results (medians, GB/s of input, 1 KiB–1 MiB unless noted)

| fold_ascii | GB/s |
|---|---|
| shipped NEON | 49–52 |
| previous NEON (`3e64286^`) | 34–36 |
| scalar at `-O2` (auto-vectorized) | 50–52 |
| scalar at `-O2`, no vectorization | 3.6–3.8 |
| **scalar at `-Os`, as shipped** | **1.9** |

| index_of_nonascii, full scan | GB/s |
|---|---|
| shipped NEON | 21–27 |
| scalar, any setting (early exit: never vectorized) | 3.0–3.3 |

At 64 bytes the dispatchers lose about half: fold 13 GB/s through `adf_fold_ascii` against 24 calling
the NEON kernel directly; scan 9 against 13.

## What holds and what does not

- Holds: the old NEON fold ran at 0.68–0.70× scalar `-O2` (claimed 0.67×); the new one is at parity
  (claimed 1.02×); 35 → 52 GB/s (claimed 36.1 → 53.2); about 14× unvectorized scalar (claimed 13.1×).
- False: "`-O2` is how Aemi builds". SwiftPM builds this target at `-Os`, where clang does not
  vectorize the scalar fold. Against what ships, the NEON kernel is about **27×** faster, and
  ADR-0008's option of accepting clang's version would have been a 27× regression.
- Overstated: `index_of_nonascii` is about **8×** scalar from 64 KiB up (7× at 1 KiB, 4× at 64 B
  directly), not 12×.

## Consequences

- The hand-written NEON kernels stay; their value is set by the `-Os` build, not by `-O2`.
- Open: the dispatchers' per-call cost on short inputs (`adf_kernels_isa()` plus a switch across a
  translation unit) is a measured follow-up, not fixed here.
- Kernel performance claims cite this harness and its output, not one-off probes.

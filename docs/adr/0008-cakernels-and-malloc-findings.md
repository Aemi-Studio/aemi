---
status: accepted
date: 2026-10-18
---

# 0008 — CAemiKernels and CAemiTestKitMalloc: correctness holds, two real defects found

## Context

Both are load-bearing. `CAemiKernels` is the SIMD byte-kernel tier every fast path runs on, and
`CAemiTestKitMalloc` is the instrument every allocation assertion in the ecosystem depends on — the
"fewest allocations" runtime principle is only enforceable because of it. Neither had been measured or
correctness-probed.

## CAemiKernels — correctness: clean

Every kernel family was compared against its `_scalar` reference over:

- lengths 0…65 (empty and every odd length, forcing tail handling repeatedly)
- **64 unaligned start offsets** — a kernel assuming 16- or 32-byte alignment passes on aligned data
- **all 256 byte values**, singly and paired with their complement
- 4,000 randomised inputs including high bytes, controls, quotes and backslashes
- 40 long buffers (1–10 KB) where a vector-width slip would show

**Result: 0 mismatches across every family** — `fold_ascii`, `index_of_nonascii`,
`index_of_string_stop`, `first_invalid_utf8`, `first_disallowed_text`.

## CAemiKernels — performance: one real defect

`adf_fold_ascii`'s hand-written NEON path is **slower than the scalar reference compiled at `-O2`** —
which is how Aemi actually builds.

| Baseline | fold_ascii speedup |
|---|---|
| true scalar (`-fno-vectorize`) | **9.5x faster** |
| scalar at `-O2` (auto-vectorised by clang) | **0.67x — 33% slower** |

Consistent at every size from 1 KB to 8 MB (0.65–0.72x), so it is not a memory-bandwidth artefact.
The NEON kernel is well written — it beats true scalar by nearly an order of magnitude — but clang
generates better code for this operation than we do by hand. `index_of_nonascii` meanwhile is 12x,
so this is specific to `fold_ascii`, not to the tier.

**Not yet decided** whether to unroll the NEON loop or accept clang's version for this operation.
Recorded as an open question rather than a fix, because the right answer needs the same measurement
reproduced first.

## CAemiTestKitMalloc — correct for its own thread

| Probe | Result |
|---|---|
| Body that allocates nothing | **0** — the floor is genuinely zero |
| 1,000 mallocs | **1,000** exactly |
| 10,000 mallocs | **10,000** exactly, ratio 10.00x |
| Sequential windows | independent, no leakage |
| A worker thread counting **its own** allocations | **1,000** exactly |

## CAemiTestKitMalloc — defect: it is not process-wide

The header and the Swift wrapper both describe it as process-wide counting. **It is not.**

A thread that allocated **before** the hook was installed is invisible. Demonstrated directly: with
the hook installed by the main thread and a worker provably allocating **1,006 blocks during the
window**, the counter reported **0**. The same worker, counting its own allocations, sees them
exactly.

Mechanism is consistent with libmalloc resolving the logger pointer per thread at first use: a thread
already warmed on malloc keeps the old pointer.

**Consequence, and it is the serious one:** an allocation assertion over code running on an
already-warm thread pool **under-reports and can pass while the code allocates**. In a Swift 6 project
with strict concurrency, that is most real code. Every allocation ceiling in the ecosystem is only
trustworthy on a single thread, and that restriction is currently undocumented at the point of use.

## Measurement notes — three artefacts caught

Each of these produced a confident wrong answer first, and each is worth remembering:

1. **Dead-code elimination.** `adf_fold_ascii_scalar` is inlinable; clang deleted its stores, making
   it report 53 GB/s — impossible for the branchy code it emits. Fixed by consuming the output.
2. **The same trap again**, with a worker's `malloc`/`free` pair elided entirely.
3. **Measuring before the subject runs.** The concurrency probe read 0 because the worker had been
   scheduled 0 times. Fixed with a rendezvous that waits for it to prove it is running.

A measurement that cannot fail proves nothing — and three of these could not fail.

## Consequences

- `CAemiKernels` and `CAemiTestKitMalloc` are exported as **products**, which they were not. A
  dependent that also used `AemiKernel` could not resolve `CAemiKernels` at all, so the ecosystem's
  own instrumentation was unreachable from inside a consumer. Measured in TerminalKit.
- The process-wide limitation is documented at the point of use, not only here.
- `fold_ascii` needs a decision, backed by a reproduction.
---
status: accepted
date: 2026-11-02
---

# 0027 — Every C kernel is checked exhaustively at its edges, fuzzed, run from many threads, built for Linux, and its checks are mutation-tested

## Context

The owner asked that every kernel, the cryptographic ones included, be tested and hardened so that its reliability is enforced
rather than assumed. Before this, each family had a differential check against its scalar reference (`bench-c-kernels.sh --check`,
`pair-set-check.sh`, `checksum-kernels-check.sh`, `argon2/check.sh`, the codec checks of ADR 0025 and 0026), the Swift guard-page
tests (ADR 0021), a Swift libFuzzer target for some scanners (Linux CI only) and the dudect timing check for the constant-time
code. Three gaps: a check only proves what it was shown, and nobody had measured what its checks miss; a defect shared by a
kernel and its own scalar reference is invisible to a differential check; and Linux x86-64, where a `target` attribute slip broke
the build once (aemi ca34b52), had no runtime check at all.

## Decision

1. **Exhaustive edges.** `Benchmarks/CKernels/codec_exhaustive.c` and `kernels_exhaustive.c` compare every backend with the scalar
   reference on: every byte value at every position of inputs around each vector width (16, 32, 64 and the overlapping tails),
   inputs flush against an inaccessible page at either end, every UTF-8 sequence of one to three bytes and every four-byte lead
   with boundary continuations, every `%XY`, every binary haystack to 13 bytes with every needle to 5, counts past every
   accumulator's flush (255 vectors, 2048 blocks), the CRC split at every point, and every date of a sample of years (every month
   edge of all years) against an independent calendar (Hinnant's eras for Gregorian, Meeus for Julian).
2. **Published answers.** `Scripts/argon2/kat-check.c` computes BLAKE2b-512 of "abc" and of "" (RFC 7693) and RFC 9106's three
   Argon2 test vectors with H0 and H' written there over the kernel's compress and fill, for every backend and 1 to 4 threads; and
   checks `adf_crypto_equal` (a difference at every position and bit, every difference value), `adf_crypto_wipe` (exactly its
   bytes, guard pages around) and `adf_argon2_allocate` (refusing sizes that wrap to zero, one block or a few).
3. **Threads.** `codec_threads.c` calls every CAemiKernels kernel from 16 threads from the first call on (when dispatch resolves
   the CPU), and the Argon2 published answers run with several fill threads, both under ThreadSanitizer.
4. **Fuzzing.** `codec_fuzz.c`, `kernels_fuzz.c` and `Scripts/argon2/fuzz.c` are libFuzzer targets over every kernel and backend
   (round trips for the codecs), run by `Scripts/kernels-fuzz.sh` natively and under Rosetta (SSSE3, AVX2). On macOS this needs a
   swift.org toolchain's clang (Xcode's has no libFuzzer); on Linux the image's clang.
5. **Linux.** `Scripts/linux-kernels-check.sh` runs every check (and, with `FUZZ_SECONDS`, the fuzzers) in Apple's `container`
   with the Swift image, arm64 natively and x86-64 translated. CI gains `c-kernels-linux-x86`: the same on a real x86-64 runner,
   with a minute of fuzzing per target. `kernels-check.sh` also compiles the libc-free codec kernels for Linux x86-64 and arm64
   at -O0 and -O2 on every run.
6. **Mutation testing.** `Scripts/kernels-mutate.py` plants each mutant of `Scripts/mutants/{codec,kernels,crypto}.txt` (an
   off-by-one bound, a wrong constant or table entry, a dropped validity test, a target slip, an early exit in the constant-time
   compare, a short wipe, a missing overflow check) in a copy of the tree and requires its check to fail. A survivor is a hole.

`codec-kernels-check.sh` becomes `kernels-check.sh`: it now runs every CAemiKernels harness.

## What the mutants found (then fixed in the checks)

Of 62 mutants, these survived the checks as they were, and each led to a stronger check:

- A lines encoder writing an ending after the last line: the exhaustive check gave it no spare room. Now it gets room too.
- The NEON set count wrapping its byte counters after 255 vectors: no input was long enough. Now 4 KiB to 1 MiB of members.
- The search's give-up skipping the very start where the budget ran out: now the needle is placed at every start around it.
- `adf_argon2_allocate` without its overflow test: `SIZE_MAX / 1024 + 1` blocks wraps to 0 bytes, which mmap refuses anyway. Now
  counts that wrap to one block and to a few are tried too.
- Five were equivalent (no behaviour changes: a compare that rereads a byte the filter already matched, a lane that can never be
  the first set one, a permute picking a duplicated half, `>> 31` against `>> 8` on a value below 256, a word mask on a length
  below 8) and were replaced by mutants that do change behaviour.

## Evidence (2026-11-02)

- Local, arm64: `kernels-check.sh` (Base64 67,200 per backend, hex 14,400, percent 39,984, find 15,887, exhaustive codecs
  41,161,135, exhaustive kernels 20,872,265, threads), `argon2/check.sh` (6,060 per backend, published answers 87,766, TSan),
  `pair-set-check.sh`, `checksum-kernels-check.sh`: 0 failures, natively and under Rosetta (SSSE3, AVX2).
- Linux in `container`: arm64 and x86-64 (translated): every check 0 failures; 20 s of each fuzzer, no finding. ThreadSanitizer
  cannot map its shadow memory in the translated x86-64 VM; there it is skipped and says so.
- Fuzzing on macOS: 15–30 s per target natively and under Rosetta, no finding; a planted defect (hex accepting `g`) was found
  within the first 30-second run.
- Mutation testing: all 62 mutants killed in one full run after the fixes above.

## Not done

- Real x86-64 hardware locally (the Intel Mac was not reachable): CI's `c-kernels-linux-x86` is the first run on it.
- Mutation testing and long fuzzing in CI: the mutants take tens of minutes; they are run before a kernel change lands.
- The Swift libFuzzer target (AemiKernelsFuzz) still covers only some scanners; the C targets cover every kernel.

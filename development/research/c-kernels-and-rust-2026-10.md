# The C kernels, reviewed, and whether Rust should replace C (2026-10-29)

Asked by the owner: review the kernels, and investigate replacing C with Rust in them.

## What the C is

`CAemiKernels`, 2,007 lines: `adf_scan.c` (653: string stops, single byte, five bytes, non-ASCII, control-or-five, printable text,
Hamming), `adf_utf8.c` (278: first invalid UTF-8), `adf_teddy.c` (238: pair sets, from AemiRegex, ADR 0018), `adf_fold.c` (166: ASCII
folding), `adf_cpu.c` (112: ISA detection, resolved once per process with `pthread_once`), `adf_numeric.c` (107), `adf_set.c` (86: nibble
set, ADR 0015), `adf_date.c` (80), `adf_neon_scan.h` (93: the shared NEON loop of ADR 0014), the header (194). Every kernel has a scalar
reference; the Swift tests compare the host's dispatched kernel with it.

| File | NEON | SSE2 | SSSE3 / SSE4.2 | AVX2 | AVX-512 |
|---|---|---|---|---|---|
| adf_scan.c | yes | yes | yes | yes | yes |
| adf_fold.c | yes | yes | — | yes | — |
| adf_utf8.c | yes | yes | — | — | — |
| adf_set.c, adf_teddy.c | yes | — | yes | — | — |

## Findings

1. **No x86-64 code runs in CI.** The test matrix is `macos-26` (arm64), and the Swift tests run only the host's backend. Under Rosetta,
   which this machine had to install for ADR 0018's check, `adf_kernels_isa()` reports SSE4.2 at most, so the SSE2 and SSE4.2 kernels
   can be checked from an arm64 Mac and **the AVX2 and AVX-512 kernels have never been executed here**. Fixed in part: a `c-kernels` CI
   job now runs the sanitized differential checks (`bench-c-kernels.sh --check`, `pair-set-check.sh`, the latter also as x86-64 under
   Rosetta). Owed: an x86-64 runner with AVX2 (and AVX-512) for the same checks; GitHub's Linux runners are x86-64, but the scripts are
   written for macOS and were not tried there.
2. **The sanitized differential check was not in CI either** (it passes: 0 mismatches over 6 fold and 5 scan variants; the pair-set check:
   104,830 checks on arm64 and on x86-64 under Rosetta).
3. **x86-64 pays `pthread_once` on every dispatched call** (ADR 0014 measured arm64 without it, and left x86-64 as it was). Small, and
   unmeasured on x86-64: no x86 machine.
4. **The x86-64 loops repeat themselves.** NEON has one shared loop (`adf_neon_scan.h`, ADR 0014); the SSE2 and AVX2 kernels in
   `adf_scan.c` are written out per kernel, which is most of its 653 lines. An SSE/AVX analogue of the shared loop would shrink them, and
   is worth doing only together with finding 1, so the result can be run.
5. **Where Swift is enough, Swift won.** AemiRegex's pair scan and small-set scan are inlinable Swift SIMD and, called once per candidate,
   beat the C nibble kernel by 13% (ADR 0018), because they inline into the caller. C remains where Swift cannot express the operation:
   a variable byte shuffle (`tbl`, `pshufb`), as ADR-0004 of AemiRegex measured.

## Rust: a prototype

`adf_index_of_set` ported to Rust (`no_std`, `core::arch::aarch64`, the same NEON lookup and 64-byte step, the scalar reference on
slices), built as a static library (`opt-level = "s"`, LTO, `panic = "abort"`) and linked into one C harness with the C kernel compiled as
SwiftPM compiles it (`-Os`, strict flags):

- **Same answers**: 296,575 checks on random sets, haystacks and start offsets, no mismatch with the C kernel or the scalar reference.
- **Same speed**: 16 bytes 1.9 against 1.9 ns, 64 bytes 2.7 against 2.4, 1 KiB 28.6 against 28.2, 64 KiB and 1 MiB equal (median of 15).
- **Size**: the static library is 1.39 MB, but the linked harness is 50 KB: `core` is dead-stripped.
- **SwiftPM can link it**: an xcframework made from the library and a module map, as a `binaryTarget`, called from a Swift executable,
  on macOS arm64.

What it would cost:

- **Safety gained is small where the risk is.** The SIMD bodies are `unsafe` in Rust as in C (`core::arch`), with the same load bounds to
  reason about; what Rust adds is bounds-checked slices in the scalar paths and defined overflow, which the scalar references, tested and
  sanitized, already cover.
- **Packaging.** SwiftPM does not build Rust: every platform slice would be a prebuilt binary (macOS arm64 and x86-64, iOS and its
  simulators, tvOS, watchOS including `arm64_32`, visionOS, Linux), released and checksummed, and every consumer would lose building aemi
  from source. The toolchain here (Homebrew's) has only the host's `core`; the others need rustup, and some Apple targets (watchOS,
  visionOS, tvOS) were tier 3 as far as I know, which means a nightly toolchain building `core` itself. Not verified here.
- **Linux**: artifact bundles of static libraries for Linux; untried.

## Recommendation

Do not replace C with Rust now: the prototype is as fast and as correct, and the gain does not pay for prebuilt binaries on nine platform
slices and the loss of source builds. Spend the effort where the risk is instead: run the x86-64 kernels at all (finding 1), keep the
sanitized differential checks in CI (done), and prefer inlinable Swift SIMD wherever Swift can express the operation (finding 5).
Revisit Rust if a kernel grows logic beyond a SIMD loop (a parser, a normaliser) where bounds-checked code matters, or if SwiftPM gains
first-class Rust builds.

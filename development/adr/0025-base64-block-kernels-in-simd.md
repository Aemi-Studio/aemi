---
status: accepted
date: 2026-10-31
---

# 0025 — Base64 takes whole blocks through SIMD kernels in C (NEON, SSSE3, AVX2), and keeps every policy in Swift

## Context

`Base64` (AemiKernel) was plain Swift: one table lookup per symbol on encode, four per group on decode. The question was whether
to move it to ARM assembly kernels, with unrolling and the arm64 features, reusing the kernels we have.

## Decision

- **Intrinsics in C (`adf_base64.c`), not hand-written `.S`.** Every kernel here is C with NEON intrinsics, and the Rust
  prototype (research note, 2026-10-29) matched them. The disassembly of the decode loop (`objdump -d`) is the loop one would
  write: `ld4`, 4× (`tbl`, `add`, `tbx`), a short `orr` tree, `uqsub`+`umaxv`, `sli`×3, `st3`; no spills. What limits it is
  `tbl`/`tbx` and `ld4`/`st3` throughput, which assembly does not change. A `.S` file would add Mach-O/ELF and `arm64_32`
  variants and leave the sanitizer checks behind.
- **Encode**: `ld3` (16 groups split into a/b/c), shifts and `sri` make the sextets, `tbl` over the 64-byte alphabet in four
  registers makes the symbols (so any alphabet works), `st4`. Unrolled twice (96 bytes). Whole 48-byte blocks only.
- **Decode**: `ld4`, then `tbl` on `lut[0..<64]` and `tbx` on `lut[64..<128]` (index − 64), `sli` to pack, `st3`; 64 symbols per
  step. A byte of 0x80 or over is caught by an explicit test (`tbl` yields 0 out of range); a symbol outside the alphabet gives
  0xFF from the table. A block with a bad byte is not stored: the kernel returns before it, and the existing scalar loop and
  byte engine take over, so every error and its offset are the ones the byte engine reports. The kernel never sees padding,
  whitespace, columns or limits: `consumeQuanta` caps the call so it cannot cross the line limit or write past `limit`.
- No lookup indexes memory with a symbol, so the kernels' timing does not depend on the data (the old table loop's did).
- **x86-64** has no 64-byte table lookup, so SSSE3 and AVX2 kernels compute the symbols (Muła and Lemire's reduction for
  encode: `pshufb` picks an offset by `subs(s, 51)`; decode: range compares and `maddubs`/`madd` to pack). They serve alphabets
  shaped `A-Za-z0-9` + two symbols (standard, URL-safe, and any custom one like it); `AlphabetTable.rangedTail` (`plus | slash << 8`,
  0 otherwise) carries that shape to the kernel, and any other alphabet runs the C scalar reference, which is still faster than the
  Swift loop it replaced. SSSE3 steps are 12 bytes to 16 symbols and back; AVX2 steps are 24 to 32. Dispatch is `CAemiCPU`'s feature
  set. **In a process translated by Rosetta 2 the dispatcher takes SSSE3 even when AVX2 is advertised**, because Rosetta ran the AVX2
  kernels slower (below). The named backends `_ssse3` and `_avx2` self-guard and are what the differential checks call.
- Other architectures compile the scalar references; Swift's own tail loops finish the remainder.

## Tried and dropped

- Unrolling decode twice (128 symbols): no change (8.5 GB/s either way at 1 MiB); removed.
- A comparison-only decode for alphabets that start `A-Za-z0-9` (no table): 5.2 GB/s against 10.7 GB/s for `tbl`/`tbx`; removed.

## Measured (Apple M3, release, one thread, best of 7; Swift = `Base64.encode/decode(options: .strict)` end to end, including the result allocation)

| Input | Encode before → after | Decode before → after | Decode `.mime` before → after |
|---|---|---|---|
| 64 B | 0.56 → 0.64 GB/s | 0.42 → 0.50 | 0.40 → 0.49 |
| 256 B | 1.28 → 2.25 | 0.99 → 1.68 | 0.93 → 1.28 |
| 1 KiB | 2.20 → 7.45 | 1.41 → 4.96 | 1.30 → 2.71 |
| 64 KiB | 2.88 → 20.7 | 1.70 → 11.3 | 1.55 → 3.88 |
| 1 MiB | 2.90 → 22.0 | 1.70 → 11.6 | 1.55 → 3.94 |

Below about 100 bytes the ~90 ns of the result allocation dominates and nothing changes; at 16 B no block is complete.
The kernels alone (`Scripts/base64-kernels-check.sh --bench`, against their C scalar references): encode 3.5 → 22.6 GB/s, decode
3.1 → 11.7 GB/s of output.

### x86-64 under Rosetta 2 (translation: indicative only, not real x86 hardware), same Swift benchmark, 1 MiB

| | Encode | Decode | Decode `.mime` |
|---|---|---|---|
| Swift before | 2.05 GB/s | 0.59 | 0.52 |
| SSSE3 kernels | 6.20 | 3.76 | 1.50 |
| AVX2 kernels (`ROSETTA_ADVERTISE_AVX=1`, forced) | 2.2 | 1.5 | 0.87 |

The kernels alone: scalar C 2.2 / 0.74 GB/s, SSSE3 6.25 / 3.77, AVX2 2.2 / 1.6. Rosetta's AVX2 is a translation to 128-bit NEON, so
nothing here says how the AVX2 kernels run on an Intel core; the next section does.

### x86-64 on real hardware: Intel Core i5-8500B (Coffee Lake, AVX2, no AVX-512), macOS 15.6, Swift 6.3.2, release

Swift end to end at 1 MiB (an Apple-silicon Mac, 2026-11-02): encode 1.08 → **11.45** GB/s, decode 0.60 → **6.24**, `.mime` decode 0.55 → 1.28;
at 1 KiB encode 0.83 → 2.68, decode 0.49 → 1.80. The kernels alone (`Scripts/base64-kernels-check.sh --bench`), 1 MiB, input GB/s for
encode and decoded-output GB/s for decode: scalar C 1.48 / 1.37, SSSE3 6.32 / 3.45, **AVX2 11.34 / 6.08**. AVX2 is 1.8× SSSE3 here, and the
dispatcher chooses it natively, so the rule that sends a Rosetta process to SSSE3 (where AVX2 was slower) costs nothing on real hardware.
The sanitized differential check (67,200 checks per backend, ASan and UBSan) and `AemiBase64Probe` (189,708 checks) pass on it with 0 mismatches.

## Checks

- `Scripts/base64-kernels-check.sh`: 67,200 differential checks per backend (dispatched, SSSE3, AVX2; four alphabets: standard,
  URL-safe, `A-Za-z0-9*,`, and a shuffled one; every length 0…699; a bad byte at a random position), with exact-size buffers
  under AddressSanitizer and UBSan, native arm64 and x86-64 under Rosetta 2, SSSE3 and AVX2 advertised: 0 mismatches. Mutation
  checks: loosening the SSSE3 decode bound by 8 bytes gives a heap-buffer-overflow; a wrong compare constant in the encode
  reduction gives 23,186 mismatches.
- `AemiBase64Probe` (`swift run --arch x86_64 AemiBase64Probe`, with and without `ROSETTA_ADVERTISE_AVX=1`): 189,708 Swift-level
  checks per tier (all four alphabets, every length to 400, a bad byte at every position of every 5th length, limits, 1 MiB round
  trips; contiguous against the byte engine), 0 failures on arm64 and on x86-64 under Rosetta. The test target itself does not
  build for x86-64 (`ShortestDoubleTests.swift:49`, a Double literal that underflows there; unrelated, not fixed), hence the probe.
- `Base64BlockKernelTests`: encode at every length 0…400 under four presets; a bad byte of seven kinds at every position of
  four presets and five lengths, contiguous (kernel) against non-contiguous (byte engine) — same value or same error and offset;
  output-size and line-limit boundaries. The existing 74 Base64 tests pass.

## Hardening of the kernel facade

The block kernels are `package` API, not public: a tight contract (an output that holds what the kernel may write, tables of exactly
64 and 256 bytes) with one caller. They take buffers, not pointers and counts, and trap on any breach before the C runs:
a table of the wrong size, an output smaller than `count / 3 * 4` (encode) or `count / 4 * 3` (decode), input and output sharing a
byte; and on a kernel answer that is not a multiple of 3 (4) or exceeds the input. Beside it:

- `foldASCII` traps on an overlap that is not the same buffer (the kernels support exactly in-place).
- `hammingScan` traps when `width` could overflow the `UInt32` distance or `width * count` overflows; a new buffer overload checks
  `query`, `corpus` and `out` against `width` and `count`. The pointer form stays for existing callers and can only check overflow.
- `AemiKernelsBase64Tests`: the kernels with input and output (sized exactly) against guard pages at both edges, every length to
  200 and around 255…4097, a bad byte at the end and the middle; and process-exit tests that each breach above traps. Removing the
  output-size check makes the suite fail. Not covered: a raw pointer that is simply wrong (any `Unsafe*` API has that), and the
  public `CAemiKernels` C header, which a client can still call directly.

AemiProtobuf's `ProtoJSONBase64` now uses this codec instead of its own scalar one; its tests keep the old decoder as an oracle
(about 20,000 valid, damaged, URL-safe and mixed-alphabet strings agree), on the pinned aemi and on this one.

## Wrapped text (.mime, .pem), 2026-11-02

`.mime` decode was 1.28 GB/s on the i5-8500B and 3.9 on the M3: a 76-symbol line was one kernel call for 64 symbols, 12 symbols
in the scalar loop, and the line break through the byte engine. Now:

- **Line kernels** (`adf_b64_decode_lines`, `adf_b64_encode_lines`): whole lines of exactly `width` symbols and their LF or CR LF in
  one call. Decode stops before any other line (shorter, longer, a bad byte, padding, a lone CR, the end, no room), which the byte
  engine then takes, so every error and offset is still its own. Encode writes every line but the last in place, endings included;
  the last line is written after them, so wrapping no longer moves the text. On x86-64 the line loops are compiled per ISA with the
  block kernel inlined: through a per-line dispatch (each `adf_cpu_has` is a `pthread_once`) `.mime` encode was 3.1 GB/s, inlined 6.8.
- **Tails by overlap**: every block kernel now consumes every whole group. The last 4–12 symbols (or 3–45 bytes on encode) are one
  more vector step that ends on the last whole group and rewrites bytes already done with the same values, instead of a scalar loop.
  A block holding a bad byte goes to the scalar reference, so every backend returns exactly the reference's answer, which the checks
  now require (equality, not "at most").

| 1 MiB, Swift end to end | i5-8500B before → after | M3 before → after (load was high; indicative) |
|---|---|---|
| `.mime` decode | 0.55 → 1.28 → **4.34** GB/s | 3.9 → **7.3** |
| `.pem` decode | 0.55 → 2.6 → **4.64** | – → **7.5** |
| `.mime` encode | 0.96 → 5.8 → **6.83** | – → **10.4** |

Checks: the C differential (now also line decode, 5,600 cases with damaged lines, lone CRs and short outputs, and line encode, 2,642)
under ASan/UBSan on arm64, Rosetta (SSSE3, AVX2) and the i5-8500B; `wrappedTextWithADamagedByteAnywhereIsReportedLikeTheByteEngine`
(a damaged, removed or inserted byte across `.mime`/`.pem`, LF/CRLF, and limits inside a line); guard-page tests for both line kernels.

## Not done

- AVX-512/VBMI kernels (no such CPU here); AMD cores; Linux (arm64 or x86-64): not built or run.
- Hex and percent coding could use the same `tbl` approach.

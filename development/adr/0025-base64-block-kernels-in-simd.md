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
nothing here says how the AVX2 kernels run on an Intel or AMD core; that is **unmeasured**.

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

## Not done

- **`.mime`/`.pem` decode** gains less (3.9 GB/s): a 76-column line is one 64-symbol block, 12 symbols of scalar and a line
  break. A 32-symbol step and encoding wrapped lines straight into place would help; unmeasured.
- Real x86-64 hardware (AVX2 speed, and whether AVX2 beats SSSE3 as expected); AVX-512/VBMI kernels; Linux (arm64 or x86-64): not built or run.
- Hex and percent coding could use the same `tbl` approach.

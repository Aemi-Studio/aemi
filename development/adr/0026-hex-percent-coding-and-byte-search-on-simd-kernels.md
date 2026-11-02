---
status: accepted
date: 2026-11-02
---

# 0026 — Hex gains a bulk API, and Hex, PercentCoding and ByteSearch run on SIMD kernels that cannot be driven out of bounds or into quadratic time

## Context

The API review of 2026-11-01 found three byte loops in AemiKernel with no kernel: `Hex` (per-digit helpers only, no bulk API),
`PercentCoding` (0.3–0.5 GB/s, a closure call per byte) and `ByteSearch` (0.20 GB/s, three times slower than libc `memmem`). The
owner asked for kernels for all three, relying as little as possible on libc, and hardened so the fast paths cannot be abused.

## Decision

The same shape as Base64 (ADR 0025): C kernels in `CAemiKernels` with intrinsics (NEON; SSSE3/AVX2 or SSE2 on x86-64; scalar
references), a `package` facade in `AemiKernels` that takes buffers and checks every size, overlap and answer with a `precondition`,
and the policy (errors, offsets, allocation) in AemiKernel's Swift. Every vector backend returns exactly the scalar reference's
answer: a block holding a bad byte is handed to the reference. Tails are one more vector step overlapping bytes already done.

- **Hex** (`adf_hex.c`): `tbl`/`pshufb` over the 16 digits and `st2`/unpack to interleave; decode with `ld2`, range compares and
  `sli` (NEON) or `maddubs` + `packus` (x86). New public API: `Hex.encode(_:uppercase:)`, `encodedString`, `encode(_:into:)`,
  `Hex.decode(_:)` for byte collections and strings, `decode(_:into:)`, with `Hex.DecodeError.invalidByte(_:offset:)` (the first bad
  byte, wherever it is), `.oddLength`, `.outputBufferTooSmall`.
- **PercentCoding** (`adf_percent.c`): the escaped bytes are a nibble-table set (`AemiKernels.ByteSet`; the unreserved complement
  needs six rows of eight). A count pass sizes the output exactly; encode copies 16-byte blocks with no escape and, in a block with
  some, copies the runs between them; decode copies blocks with no `%` (nor `+` for forms) likewise. `encode(_:allowed:)` asks the
  predicate once per byte value (for 64 bytes and more) and uses the kernels when the set fits; otherwise the byte loop. The encoder
  writes nothing at or past its capacity (it returns `SIZE_MAX` instead, which the facade turns into a trap).
- **ByteSearch** (`adf_find.c`): Muła's filter (a start is a candidate when its first and last bytes match) then an 8-byte compare.
  A crafted input can make every start a candidate (`aaa…` against `aa…ab…a`): the bytes compared are counted against a budget
  linear in the haystack (`8 * hlen + 4 * nlen + 4096`), past which the kernel stops and reports how far it has ruled out starts;
  `AemiKernels.firstIndex(of:in:)` finishes with Knuth-Morris-Pratt from there. So the search is linear for every input.
  The `memmem` it replaces measured slower than the plain reference loop here.

## Measured (1 MiB unless noted; M3 under other load, so indicative; i5-8500B idle)

| | M3: before → after | i5-8500B: kernel alone, scalar → SIMD |
|---|---|---|
| Hex encode (kernel) | 2.4 → 30 GB/s | 1.3 → 16–21 |
| Hex decode (kernel) | 0.9 → 10.4 | 0.13–0.4 → 8.6–9.1 |
| PercentCoding.encode, no escapes (Swift) | 0.53 → 12.6 | kernel 1.2 → 6.4 |
| PercentCoding.encode, 1 in 8 escaped (Swift) | 0.49 → 4.4 | kernel 1.1 → 2.2 |
| PercentCoding.decode, 1 in 8 escaped (Swift) | 0.54 → 2.8 | kernel 1.2 → 1.9 |
| ByteSearch.firstRange, 8-byte needle (Swift) | 0.20 → 30 | kernel 0.8 → 22 (`memmem` 1.1) |

Half the bytes escaped is the worst case for percent-coding: there the kernels are no faster than the C reference (and on the
i5-8500B decode is 0.84 against 1.32 GB/s for the reference), still above the Swift loop they replace (0.5 GB/s).

## Checks

- `Scripts/codec-kernels-check.sh` (renamed from `base64-kernels-check.sh`; `KERNELS=` selects harnesses): hex 14,400 checks per
  backend (every length to 599, both cases, mixed-case decode, a bad byte, odd lengths), percent 39,984 (two sets, four densities,
  one byte short of capacity, damaged and form decodes), find 8,048 (small alphabets, present and absent needles, and the
  adversarial inputs, 16 of which give up as designed and must rule out exactly the starts before `resume`). ASan and UBSan, exact
  allocations; arm64, Rosetta SSSE3 and AVX2, and the i5-8500B: 0 mismatches.
- Swift: `HexBulkTests`, `PercentCodingKernelTests`, `ByteSearchKernelTests` (including adversarial searches that must stay under
  two seconds in a debug build, and correct), guard-page tests for each facade (`AemiKernelsHexTests`, `AemiKernelsPercentTests`,
  `AemiKernelsFindTests`), and process-exit tests that a short output or an overlap traps.
- `AemiCodecProbe` (renamed from `AemiBase64Probe`) adds the three: 191,515 checks, 0 failures on arm64, Rosetta SSSE3 and AVX2,
  and the i5-8500B.

## Not done

AVX2 for percent-coding (SSSE3 only) and a dense-escape path that beats the reference; `Varint` bulk decoding (no bulk caller).

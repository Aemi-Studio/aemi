---
status: accepted
date: 2026-10-30
---

# 0020 — MacFS promotes CRC-32C, a bit count and UTF-16LE narrowing into CAemiKernels

## Context

MacFS (read-only Btrfs, NTFS and ext readers for macOS) wrote three kernels that are not about file systems: CRC-32C (Btrfs node and
data checksums, ext4 metadata checksums; also iSCSI, Snappy framing, and the page checksums storage engines such as ADSQL's would
carry), the set bits of a buffer (allocation bitmaps), and the ASCII prefix of UTF-16LE text (NTFS names; any Windows format). aemi
had none of the three; `adf_hamming_distance` is the nearest, and the bit count is it without the XOR. The owner asked that MacFS's
improvements be promoted into aemi where they belong.

## Decision

| Kernel | Where | Backends |
|---|---|---|
| `adf_crc32c_update` (raw: no inversion) | `adf_crc32c.c`, `AemiKernels.crc32c` | arm64 with CRC32 and PMULL: eight 128-bit accumulators folded with PMULL from 256 bytes; x86-64 SSE4.2 `crc32`; a byte table |
| `adf_bit_count` | `adf_numeric.c`, `AemiKernels.bitCount` | NEON `cnt` with widening pairwise adds (Hamming's flush rule); POPCNT-lowered words |
| `adf_utf16le_ascii_prefix` | `adf_utf16.c`, `AemiKernels.asciiPrefix` | NEON `umaxv` and `xtn`; SSE2 mask and `packus`; scalar |

`adf_kernels_has_crc32_pmull()` joins `adf_kernels_isa()` in `adf_cpu.c`: neither feature is implied by arm64 (sysctl on Darwin,
`HWCAP_CRC32`/`HWCAP_PMULL` on Linux). C intrinsics, like every aemi kernel: MacFS's hand-written arm64 assembly for the same fold
is 13% faster at `-O3` (58.7 against 52.1 GB/s) and stays in MacFS (its ADR-0011) until a measurement here says otherwise.

## Evidence

- Red first: the three test suites against zero-returning stubs, 30,335 failures; then green.
- Wrong on purpose, each red: a fold constant one bit off (1,416 failures), a flush block four times too long so a u16 lane wraps
  (all-ones input), the NEON ASCII test at 0x81, and on x86-64 a corrupted `crc32` byte (17,469 of 60,000) and a narrowing mask that
  lets 0x80 to 0xFF through (7,484 of 60,000, after the check was made to generate such units: the first version could not fail).
- `scripts/checksum-kernels-check.sh`, in CI beside the pair-set check: 60,000 checks against the scalar references under ASan and
  UBSan, natively and as x86-64 under Rosetta.
- `--bench`, at the `-Os` a release build uses, Apple M2 Pro: CRC-32C 52.2 GB/s on 64 MiB and 50.5 on 4 KiB blocks (0.43 for the
  table); bit count 59.6 (21.1 scalar); UTF-16 narrowing 35.7 (4.6 scalar). The first CRC version kept its accumulators in an array
  in a loop and ran at 20.6 GB/s at `-Os`: the eight are written out.

## Consequences

MacFS can drop its C bit count and UTF-16 kernels for these once aemi's revision is published and pinned; whether it keeps its
assembly CRC is its own measured decision. The x86-64 CRC is a single `crc32` stream; a PCLMUL fold is not written.

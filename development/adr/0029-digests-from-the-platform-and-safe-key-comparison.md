---
status: accepted
date: 2026-11-02
---

# 0029 — Digests come from the platform's cryptography, in their own module; the interner compares keys without libc

## Context

ADR 0028 added `ContentDigest.sha256` to `AemiKernel`: CommonCrypto on Apple platforms and a portable FIPS 180-4
implementation elsewhere, with no package. Two problems followed. CommonCrypto is not libc, so `AemiKernel` stopped
building as Embedded Swift (CI's `Embedded Swift, AemiKernel and AemiKernels` failed on 6ed7fb7: `CC_SHA256_*` beyond
libc). And the owner's rule for cryptography is to leverage official packages rather than implement it ourselves.

Measured (2026-11-02, M3; SHA-256 of "abc" checked on each):

| SHA-256, 1 MiB         | macOS     | Linux arm64 (swift:6.4.1-noble) |
|------------------------|-----------|---------------------------------|
| portable Swift (0028)  | 0.07 GB/s | 0.09 GB/s                       |
| CommonCrypto           | 1.31 GB/s | —                               |
| CryptoKit/swift-crypto | 1.37 GB/s | 1.61 GB/s                       |

Official options surveyed: apple/swift-crypto is the only one (CryptoKit's API; BoringSSL with its assembly off Apple
platforms). swift-foundation, swift-certificates and swift-nio-ssl add no digest. Nothing official has Argon2 or
BLAKE2b, so `AemiArgon2` stays aemi's own.

Separately, the interner compared keys with libc's `memcmp` (`Table.equal`, `Merge.same`), the last libc call in its Swift.

## Decision

1. **`AemiDigest`**, a new module and product: `ContentDigest` moves there unchanged in API (`sha256`, `sha256Hex`,
   the incremental `ContentDigest.SHA256`). It wraps CryptoKit on Apple platforms and swift-crypto's `Crypto` elsewhere
   (a dependency conditioned on the non-Apple platforms, `"4.0.0" ..< "6.0.0"`). The portable SHA-256 is deleted: aemi
   implements no digest. `AemiKernel` is dependency-free and Embedded-clean again; `AemiDigest` is not in the
   `AemiFoundation` umbrella, which takes no dependency.
2. **The interner's key comparison** reads both keys through `RawSpan`'s bounds-checked
   `load(fromByteOffset:as:)` (SE-0525, Swift 6.4): 16 bytes a step, then the last 8 or 4 bytes overlapping, so no
   byte loop runs for keys of 4 bytes or more. A load past either end traps. Under Swift 6.3, which has no safe load,
   it keeps `memcmp`. `Table.swift` and `Merge.swift` no longer import Darwin or Glibc.

## Consequences

- Callers of `ContentDigest` (litmus `Planning.swift`, analyzerkit `TreeSnapshot.swift`) add the `AemiDigest` product
  and `import AemiDigest` when they move past this revision. Until then their pins keep 0028's `AemiKernel` version.
- Linux builds of `AemiDigest` compile BoringSSL (about 100 s in the container, once per clean build).
- Key comparison, equal keys, ns (best of 7, 256 key pairs, load ~25): as fast as `memcmp` to 32 bytes (3–6 against
  4–8), two to four times slower from 256 bytes. Identifiers and USRs are mostly short.

## Evidence

- `ContentDigestTests` (FIPS 180-4 and NIST vectors, a million `a`, random inputs in random pieces against one shot) pass
  on macOS and in the Linux container; `Scripts/check-embedded.sh` passes again.
- `ByteEqualityTests`: every length to 80 and 127–4096, both buffers flush against an inaccessible page at either end; a
  difference at every position in bits 0 and 7; prefixes. Two planted defects (no 8-byte tail, no 4-byte tail) fail it.

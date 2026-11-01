---
status: accepted
date: 2026-11-01
---

# 0024 — AemiArgon2, one CPU feature set for every C kernel, and kernels that build as Embedded Swift

## Context

- **ask needs a key from a password** to encrypt sessions (ask ADR-0138, roadmap 0182). The owner chose Argon2id and
  asked for NEON kernels, every feature that makes them faster, timing safety, red-first tests, mutation runs, and an
  attack on the result. Neither CryptoKit nor CommonCrypto has Argon2.
- **CAemiKernels detected the CPU itself** (`adf_cpu.c`), as a single tier. Argon2 needs other features (SHA3's `xar`,
  DIT), and a second copy of detection had already drifted: it lacked the Rosetta guard.
- **WineKit asked for AemiKernel and AemiKernels to build as Embedded Swift** (2026-11-01), so they can link into
  Wine's `ntdll`, which can carry nothing beyond libc.
- **Adding CAemiCPU broke a script.** Five scripts hard-coded the C targets' files, so `bench-c-kernels.sh`, which
  globbed CAemiKernels alone, stopped compiling. The repository also had two script directories, `scripts/` and
  `Scripts/`, which a case-insensitive volume (any default Mac, GitHub's macOS runners) folds into one.

## Decision

### `CAemiCPU`: one feature set

- **Asked once, as a set of bits:**
  - arm64: NEON, CRC32, PMULL, AES, SHA2, SHA3, SHA512, DotProd, I8MM, BF16, SVE, SVE2, SME, DIT, SB;
  - x86-64: SSE2 up to AVX-512 VL;
  - whether the process is translated.
- **Where the answers come from:** `sysctl` on Darwin, `getauxval` on Linux, `__builtin_cpu_supports` on x86-64.
- **Rosetta:** AVX and above stay withheld under Rosetta, as before.
- **`ADF_CPU_HAS(NAME)`** folds to 1 where the target guarantees the feature.
- **CAemiKernels' interface is unchanged.** `adf_kernels_isa`, `adf_kernels_has_crc32_pmull` and
  `adf_kernels_backend` now read the set, and choose the same tiers as before: NEON+I8MM with CRC and PMULL natively,
  SSE4.2 under Rosetta.
- **`adf_cpu_timing_safe_begin` and `end`**, in their own file, turn data-independent timing on for a thread:
  - Apple's `timingsafe_enable_if_supported` from macOS 15.2, which also limits speculation;
  - otherwise PSTATE.DIT, written directly;
  - a no-op on x86-64, whose DOITM only the kernel can set.

### `AemiArgon2` and `CAemiArgon2`

- **Algorithms:** BLAKE2b (RFC 7693) and Argon2d, Argon2i and Argon2id (RFC 9106, version 0x13).
- **In Swift:** H0, H′, the first blocks of each lane and the final step.
- **In C:** G, the memory fill and BLAKE2b's F.
- **Backends:** scalar (the reference), NEON, NEON+SHA3 (`xar`), SSSE3 and AVX2. A backend the CPU lacks runs as the
  best one below it.
- **Threads:** the lanes of each slice run on threads, and the tag does not depend on how many.
- **Timing safety:**
  - no branch or table lookup on a secret;
  - the reference lane is found by a multiply (Lemire's fastmod) rather than a division, and the reference area by
    masks;
  - every public entry point, and each fill thread, runs with DIT on;
  - `ConstantTime.equal` and `adf_crypto_equal` compare in a time set by the length;
  - every buffer that held a secret is wiped by a `memset` the optimiser cannot drop.
  What Argon2 itself reveals stays: Argon2d, and Argon2id after its first half pass, read blocks chosen by the data
  (RFC 9106, 3.4).
- **Not built:** AVX-512, SVE and SME. Nothing here runs them to test against.

### Embedded Swift

- **Guarded by `#if !hasFeature(Embedded)`:** `ByteBufferPool` (`Synchronization`), `HTTPDateParser` (`String`
  parsing) and the `Character` helpers of `ASCII`. The API of a regular build is unchanged.
- **Shipped module maps:** `Sources/CAemiKernels/include/module.modulemap` and `Sources/CAemiCPU`'s.
- **`Scripts/check-embedded.sh`** builds both Swift modules as Embedded Swift for arm64 and x86_64 macOS, with the C,
  and fails on any symbol beyond libc and compiler-rt's `__cpu_model`. CI runs it on a swift.org toolchain, since
  Xcode's has no Embedded standard library.

### Build scripts

- **One directory:** `scripts/` merged into `Scripts/`, the family's convention. The reusable workflows check aemi
  out at their own commit, so each commit stays consistent with itself. Accepted ADRs and diaries keep the old paths
  as history.
- **One layout:** `Scripts/lib/c-targets.sh` holds the C targets' sources, include paths and strict flags (read from
  Package.swift), and every C check and benchmark sources it.
- **Consequences of sharing it:**
  - the Linux legs rerun the same script inside the container, rather than a copy of it;
  - the pair-set check now builds with `-Werror`;
  - no x86 build drops its sanitizers silently any more;
  - the Embedded check compiles the C with SwiftPM's strict flags.
- **CI:** `actions/setup-go` is pinned to its commit, as every other action already was.

## Evidence (Apple M3, macOS 27.2, Swift 6.4.2, 2026-11-01)

- **Correctness:**
  - every backend gives RFC 9106's three tags and 60 tags made by OpenSSL 4.1 over random parameters, on 1, 3 and 8
    threads;
  - BLAKE2b gives 120 digests from Python's hashlib;
  - G matches the scalar code on random blocks;
  - `Scripts/argon2/check.sh` passes:
    - under ASan and UBSan: scalar, NEON and NEON+SHA3 natively, scalar, SSSE3 and AVX2 under Rosetta;
    - on arm64 Linux with clang and GCC, SHA3 found at run time and given at compile time.
- **Mutations:** 28 planted bugs, across the scalar, NEON, SHA3, x86, fill, comparison, wipe and Swift code, all
  fail the tests or the C check. Two of them crash, by reading out of bounds.
- **Timing attack** (`Scripts/argon2/check.sh --timing`, dudect's Welch t-test, |t| > 4.5 is a leak):
  - the leaky early-exit comparison used as a control scores |t| in the thousands;
  - without DIT, scalar G scored |t| ≈ 12, which points to Apple's data memory-dependent prefetcher;
  - with DIT, every kernel and the Argon2i fill score under 2.6;
  - a mutation that leaves DIT off fails the check.
- **Speed:** Argon2id at 19 MiB and 2 passes:
  - NEON+SHA3 with DIT takes 9.4–10.6 ms on one lane, and 3.6–4.6 ms on 4 lanes with 4 threads;
  - OpenSSL 4.1 takes 15.1 ms, its process start subtracted;
  - DIT costs about 4% on G.
- **Rosetta:** AVX2 passes when called directly under Rosetta, so the blanket cap at SSE4.2 is now stricter than
  needed. It stays until it is measured.
- **Embedded:** the objects need exactly WineKit's list. A mutation that unguards the `Character` helpers fails with
  the four `__swift_stdlib_*` symbols WineKit reported.

## Consequences

- **A new C kernel** dispatches on `ADF_CPU_HAS`, and is added to `Scripts/lib/c-targets.sh`, not to each script.
- **An Embedded consumer** now also compiles `Sources/CAemiCPU/adf_cpu_features.c`, with that target's `include`.
- **The DIT scope is a separate file**, so CAemiKernels links no `timingsafe` call.
- **Timing checks stay local:** CI runners are too noisy for a t-test.
- **A tool that reads Argon2 parameters from a file** must bound them itself. RFC 9106 allows 4 TiB, and the library
  follows the RFC.
- **Not regenerable:** `Sources/AemiUnicode/GeneratedUnicodeTables.swift` names a generator that is not in the
  repository (`gen-unicode-tables.mjs`, since ADFoundation's absorption), so those tables cannot be rebuilt here.

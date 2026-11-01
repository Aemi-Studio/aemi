//
//  CAemiCPU.h
//  CAemiCPU
//
//  What this CPU can do, asked once per process and cached, for every C kernel of the family to dispatch on: a set of
//  features rather than a single tier, since kernels need different combinations (a CRC wants CRC32 and PMULL, Argon2
//  wants SHA3's `xar`). Darwin asks `sysctl`, Linux `getauxval`, x86-64 CPUID through `__builtin_cpu_supports`, which
//  also checks that the OS saves the wide registers. Under Rosetta 2, CPUID reports what Rosetta runs: AVX2 and BMI2
//  only when the process starts with ROSETTA_ADVERTISE_AVX=1, AVX-512 never.
//
//  `ADF_CPU_HAS(SHA3)` is a constant where the compilation target guarantees the feature (`__ARM_FEATURE_SHA3` on any
//  Apple silicon target), so the check and the fallback vanish there; elsewhere it reads the cached set.
//

#ifndef CAEMICPU_H
#define CAEMICPU_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Plain literals, so Swift imports them as constants.
// arm64
#define ADF_CPU_NEON 0x1ULL
#define ADF_CPU_CRC32 0x2ULL
#define ADF_CPU_PMULL 0x4ULL
#define ADF_CPU_AES 0x8ULL
#define ADF_CPU_SHA2 0x10ULL
#define ADF_CPU_SHA3 0x20ULL
#define ADF_CPU_SHA512 0x40ULL
#define ADF_CPU_DOTPROD 0x80ULL
#define ADF_CPU_I8MM 0x100ULL
#define ADF_CPU_BF16 0x200ULL
#define ADF_CPU_SVE 0x400ULL
#define ADF_CPU_SVE2 0x800ULL
#define ADF_CPU_SME 0x1000ULL
/// Data-independent timing (FEAT_DIT): with PSTATE.DIT set, the instructions it covers take the same time whatever their
/// operands; on Apple silicon from M3 it also turns the data memory-dependent prefetcher off.
#define ADF_CPU_DIT 0x2000ULL
/// The speculation barrier instruction (FEAT_SB).
#define ADF_CPU_SB 0x4000ULL
// x86-64
#define ADF_CPU_SSE2 0x100000000ULL
#define ADF_CPU_SSSE3 0x200000000ULL
#define ADF_CPU_SSE42 0x400000000ULL
#define ADF_CPU_PCLMUL 0x800000000ULL
#define ADF_CPU_AVX 0x1000000000ULL
#define ADF_CPU_AVX2 0x2000000000ULL
#define ADF_CPU_BMI2 0x4000000000ULL
#define ADF_CPU_AVX512F 0x8000000000ULL
#define ADF_CPU_AVX512BW 0x10000000000ULL
#define ADF_CPU_AVX512VL 0x20000000000ULL
// The process runs translated (Rosetta 2): x86-64 code on arm64.
#define ADF_CPU_TRANSLATED 0x8000000000000000ULL

/// Every feature this CPU has, as `ADF_CPU_*` bits. Resolved once (thread-safe), then a load.
uint64_t adf_cpu_features(void);

/// What `adf_cpu_timing_safe_begin` returns, to give back to `adf_cpu_timing_safe_end`.
typedef uint64_t adf_timing_token_t;

/// Turns data-independent timing on for this thread, where the CPU has it: Apple's `timingsafe_enable_if_supported`
/// (macOS 15.2 and later; it also limits speculation as the CPU needs), else PSTATE.DIT written directly. A no-op on
/// x86-64, whose equivalent (DOITM) only the kernel can set. Scopes nest; each thread sets its own.
adf_timing_token_t adf_cpu_timing_safe_begin(void);

/// 1 when this thread runs with data-independent timing on (PSTATE.DIT); 0 off arm64 or without FEAT_DIT.
int adf_cpu_timing_safe_is_on(void);

/// Restores what `adf_cpu_timing_safe_begin` found: DIT stays on if it was on before.
void adf_cpu_timing_safe_end(adf_timing_token_t token);

/// 1 when this CPU has every feature in `features`.
static inline int adf_cpu_has(uint64_t features) {
    return (adf_cpu_features() & features) == features;
}

// What the compilation target guarantees, so `ADF_CPU_HAS` folds to 1 without asking.
#if defined(__ARM_NEON)
#define ADF_CPU_GUARANTEED_NEON 1
#else
#define ADF_CPU_GUARANTEED_NEON 0
#endif
#if defined(__ARM_FEATURE_CRC32)
#define ADF_CPU_GUARANTEED_CRC32 1
#else
#define ADF_CPU_GUARANTEED_CRC32 0
#endif
#if defined(__ARM_FEATURE_AES)
#define ADF_CPU_GUARANTEED_AES 1
#define ADF_CPU_GUARANTEED_PMULL 1
#else
#define ADF_CPU_GUARANTEED_AES 0
#define ADF_CPU_GUARANTEED_PMULL 0
#endif
#if defined(__ARM_FEATURE_SHA3)
#define ADF_CPU_GUARANTEED_SHA3 1
#else
#define ADF_CPU_GUARANTEED_SHA3 0
#endif
#if defined(__ARM_FEATURE_SHA512)
#define ADF_CPU_GUARANTEED_SHA512 1
#else
#define ADF_CPU_GUARANTEED_SHA512 0
#endif
#if defined(__ARM_FEATURE_DOTPROD)
#define ADF_CPU_GUARANTEED_DOTPROD 1
#else
#define ADF_CPU_GUARANTEED_DOTPROD 0
#endif
#if defined(__ARM_FEATURE_MATMUL_INT8)
#define ADF_CPU_GUARANTEED_I8MM 1
#else
#define ADF_CPU_GUARANTEED_I8MM 0
#endif
#if defined(__SSE2__) || defined(__x86_64__)
#define ADF_CPU_GUARANTEED_SSE2 1
#else
#define ADF_CPU_GUARANTEED_SSE2 0
#endif
#if defined(__SSSE3__)
#define ADF_CPU_GUARANTEED_SSSE3 1
#else
#define ADF_CPU_GUARANTEED_SSSE3 0
#endif
#if defined(__AVX2__)
#define ADF_CPU_GUARANTEED_AVX2 1
#else
#define ADF_CPU_GUARANTEED_AVX2 0
#endif

/// 1 when this CPU has the feature `NAME` (`ADF_CPU_NAME`), folded at compile time where the target guarantees it.
#define ADF_CPU_HAS(NAME) (ADF_CPU_GUARANTEED_##NAME || adf_cpu_has(ADF_CPU_##NAME))

#ifdef __cplusplus
}
#endif

#endif

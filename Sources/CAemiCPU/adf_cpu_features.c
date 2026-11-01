//
//  adf_cpu_features.c
//  CAemiCPU
//
//  The feature set, resolved once with `pthread_once`. Moved from CAemiKernels' `adf_cpu.c` and widened from a tier to
//  a set; no `ifunc` or `target_clones` (ELF only; Mach-O has neither).
//

#include "CAemiCPU.h"

#include <pthread.h>
#include <stddef.h>

#if defined(__APPLE__)
#include <sys/sysctl.h>
#endif
#if defined(__aarch64__) && defined(__linux__)
#include <asm/hwcap.h>
#include <sys/auxv.h>
#endif

static uint64_t g_features = 0;
static pthread_once_t g_once = PTHREAD_ONCE_INIT;

#if defined(__APPLE__)
/// 1 when the named `sysctl` integer is present and nonzero.
static int adf_sysctl_flag(const char *name) {
    int value = 0;
    size_t size = sizeof value;
    if (sysctlbyname(name, &value, &size, NULL, 0) != 0) {
        return 0;
    }
    return value != 0;
}
#endif

#if defined(__aarch64__)
static uint64_t adf_arm_features(void) {
    uint64_t features = ADF_CPU_NEON;
#if defined(__APPLE__)
    static const struct {
        const char *name;
        uint64_t feature;
    } flags[] = {
        {"hw.optional.armv8_crc32", ADF_CPU_CRC32},       {"hw.optional.arm.FEAT_PMULL", ADF_CPU_PMULL},
        {"hw.optional.arm.FEAT_AES", ADF_CPU_AES},        {"hw.optional.arm.FEAT_SHA256", ADF_CPU_SHA2},
        {"hw.optional.arm.FEAT_SHA3", ADF_CPU_SHA3},      {"hw.optional.arm.FEAT_SHA512", ADF_CPU_SHA512},
        {"hw.optional.arm.FEAT_DotProd", ADF_CPU_DOTPROD}, {"hw.optional.arm.FEAT_I8MM", ADF_CPU_I8MM},
        {"hw.optional.arm.FEAT_BF16", ADF_CPU_BF16},      {"hw.optional.arm.FEAT_SME", ADF_CPU_SME},
        {"hw.optional.arm.FEAT_DIT", ADF_CPU_DIT},        {"hw.optional.arm.FEAT_SB", ADF_CPU_SB},
    };
    for (size_t index = 0; index < sizeof flags / sizeof flags[0]; index++) {
        if (adf_sysctl_flag(flags[index].name)) {
            features |= flags[index].feature;
        }
    }
#elif defined(__linux__)
    const unsigned long hwcap = getauxval(AT_HWCAP);
    const unsigned long hwcap2 = getauxval(AT_HWCAP2);
#define ADF_HWCAP(set, bit, feature)                                                                                   \
    if ((set) & (bit)) {                                                                                               \
        features |= (feature);                                                                                         \
    }
#if defined(HWCAP_CRC32)
    ADF_HWCAP(hwcap, HWCAP_CRC32, ADF_CPU_CRC32)
#endif
#if defined(HWCAP_PMULL)
    ADF_HWCAP(hwcap, HWCAP_PMULL, ADF_CPU_PMULL)
#endif
#if defined(HWCAP_AES)
    ADF_HWCAP(hwcap, HWCAP_AES, ADF_CPU_AES)
#endif
#if defined(HWCAP_SHA2)
    ADF_HWCAP(hwcap, HWCAP_SHA2, ADF_CPU_SHA2)
#endif
#if defined(HWCAP_SHA3)
    ADF_HWCAP(hwcap, HWCAP_SHA3, ADF_CPU_SHA3)
#endif
#if defined(HWCAP_SHA512)
    ADF_HWCAP(hwcap, HWCAP_SHA512, ADF_CPU_SHA512)
#endif
#if defined(HWCAP_ASIMDDP)
    ADF_HWCAP(hwcap, HWCAP_ASIMDDP, ADF_CPU_DOTPROD)
#endif
#if defined(HWCAP_SVE)
    ADF_HWCAP(hwcap, HWCAP_SVE, ADF_CPU_SVE)
#endif
#if defined(HWCAP_DIT)
    ADF_HWCAP(hwcap, HWCAP_DIT, ADF_CPU_DIT)
#endif
#if defined(HWCAP_SB)
    ADF_HWCAP(hwcap, HWCAP_SB, ADF_CPU_SB)
#endif
#if defined(HWCAP2_I8MM)
    ADF_HWCAP(hwcap2, HWCAP2_I8MM, ADF_CPU_I8MM)
#endif
#if defined(HWCAP2_BF16)
    ADF_HWCAP(hwcap2, HWCAP2_BF16, ADF_CPU_BF16)
#endif
#if defined(HWCAP2_SVE2)
    ADF_HWCAP(hwcap2, HWCAP2_SVE2, ADF_CPU_SVE2)
#endif
#if defined(HWCAP2_SME)
    ADF_HWCAP(hwcap2, HWCAP2_SME, ADF_CPU_SME)
#endif
#undef ADF_HWCAP
    (void)hwcap2;
#endif
    return features;
}
#endif

#if defined(__x86_64__)
static uint64_t adf_x86_features(void) {
    __builtin_cpu_init();
    uint64_t features = ADF_CPU_SSE2;
#define ADF_CPUID(name, feature)                                                                                       \
    if (__builtin_cpu_supports(name)) {                                                                                \
        features |= (feature);                                                                                         \
    }
    ADF_CPUID("ssse3", ADF_CPU_SSSE3)
    ADF_CPUID("sse4.2", ADF_CPU_SSE42)
    ADF_CPUID("pclmul", ADF_CPU_PCLMUL)
    ADF_CPUID("avx", ADF_CPU_AVX)
    ADF_CPUID("avx2", ADF_CPU_AVX2)
    ADF_CPUID("bmi2", ADF_CPU_BMI2)
    ADF_CPUID("avx512f", ADF_CPU_AVX512F)
    ADF_CPUID("avx512bw", ADF_CPU_AVX512BW)
    ADF_CPUID("avx512vl", ADF_CPU_AVX512VL)
#undef ADF_CPUID
#if defined(__APPLE__)
    // `sysctl.proc_translated` is absent (so 0) in a native process. Rosetta's CPUID is trusted: it reports AVX, AVX2,
    // BMI2 and FMA only when it runs them (macOS 15 on, when the process is started with ROSETTA_ADVERTISE_AVX=1), and
    // never AVX-512 (measured 2026-11-01, macOS 27; aemi ADR 0024).
    if (adf_sysctl_flag("sysctl.proc_translated")) {
        features |= ADF_CPU_TRANSLATED;
    }
#endif
    return features;
}
#endif

static void adf_cpu_resolve(void) {
#if defined(__aarch64__)
    g_features = adf_arm_features();
#elif defined(__x86_64__)
    g_features = adf_x86_features();
#else
    g_features = 0;
#endif
}

uint64_t adf_cpu_features(void) {
    pthread_once(&g_once, adf_cpu_resolve);
    return g_features;
}

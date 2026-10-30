//
//  adf_cpu.c
//  CAemiKernels
//
//  Runtime CPU-feature detection, resolved exactly once and cached (pthread_once — the same
//  one-time-init idiom CCRC32 uses for its tables). This is the piece CCRC32 omits: it fills a single
//  cached `adf_isa_t` that every kernel's dispatcher switches on. No `ifunc`/`target_clones` (ELF-only;
//  Mach-O has none) — a plain cached int + switch works identically on Darwin and Linux.
//

#include "CAemiKernels.h"

#include <pthread.h>

#if defined(__APPLE__)
#include <sys/sysctl.h>
#endif

#if defined(__aarch64__) && !defined(__APPLE__)
#include <sys/auxv.h>
#include <asm/hwcap.h>
#endif

static int g_isa = ADF_ISA_SCALAR;
static int g_crc32_pmull = 0;
static pthread_once_t g_once = PTHREAD_ONCE_INIT;

#if defined(__APPLE__) && (defined(__x86_64__) || defined(__aarch64__))
/// 1 when the named `sysctl` integer is present and non-zero.
static int adf_sysctl_flag(const char *name) {
    int value = 0;
    size_t size = sizeof(value);
    if (sysctlbyname(name, &value, &size, NULL, 0) != 0) {
        return 0;
    }
    return value;
}
#endif

static void adf_resolve(void) {
#if defined(__x86_64__)
    // __builtin_cpu_supports() already folds in the xgetbv/XCR0 OS-enable check for AVX/AVX-512, so a
    // true result implies the OS has enabled the wide register state. Preferred over hand-rolled
    // cpuid+xgetbv (which is easy to get subtly wrong).
    __builtin_cpu_init();
    g_isa = ADF_ISA_X86_SSE2;
    if (__builtin_cpu_supports("sse4.2")) {
        g_isa = ADF_ISA_X86_SSE42;
    }
    if (__builtin_cpu_supports("avx2") && __builtin_cpu_supports("bmi2")) {
        g_isa = ADF_ISA_X86_AVX2;
    }
    if (__builtin_cpu_supports("avx512f") && __builtin_cpu_supports("avx512bw")) {
        g_isa = ADF_ISA_X86_AVX512;
    }
#if defined(__APPLE__)
    // Rosetta 2 implements at most SSE4.2 (no AVX) and traps AVX as illegal, so clamp the tier
    // regardless of what CPUID claims. `sysctl.proc_translated` is absent (ENOENT) on native processes.
    if (adf_sysctl_flag("sysctl.proc_translated") && g_isa > ADF_ISA_X86_SSE42) {
        g_isa = ADF_ISA_X86_SSE42;
    }
#endif
#elif defined(__aarch64__)
    // NEON (AdvSIMD) is mandatory on arm64. dotprod / i8mm are NOT arch-implied (M1 lacks i8mm), so
    // they must be probed — a plain `#if defined(__aarch64__)` gate would be wrong here.
    g_isa = ADF_ISA_ARM_NEON;
#if defined(__APPLE__)
    if (adf_sysctl_flag("hw.optional.arm.FEAT_DotProd")) {
        g_isa = ADF_ISA_ARM_DOTPROD;
    }
    if (adf_sysctl_flag("hw.optional.arm.FEAT_I8MM")) {
        g_isa = ADF_ISA_ARM_I8MM;
    }
    g_crc32_pmull = adf_sysctl_flag("hw.optional.armv8_crc32") && adf_sysctl_flag("hw.optional.arm.FEAT_PMULL");
#else
    {
        unsigned long hwcap = getauxval(AT_HWCAP);
        unsigned long hwcap2 = getauxval(AT_HWCAP2);
#if defined(HWCAP_CRC32) && defined(HWCAP_PMULL)
        g_crc32_pmull = (hwcap & HWCAP_CRC32) && (hwcap & HWCAP_PMULL);
#endif
#if defined(HWCAP_ASIMDDP)
        if (hwcap & HWCAP_ASIMDDP) {
            g_isa = ADF_ISA_ARM_DOTPROD;
        }
#endif
#if defined(HWCAP2_I8MM)
        if (hwcap2 & HWCAP2_I8MM) {
            g_isa = ADF_ISA_ARM_I8MM;
        }
#else
        (void)hwcap2;
#endif
    }
#endif
#else
    g_isa = ADF_ISA_SCALAR;
#endif
}

int adf_kernels_isa(void) {
    pthread_once(&g_once, adf_resolve);
    return g_isa;
}

int adf_kernels_has_crc32_pmull(void) {
    pthread_once(&g_once, adf_resolve);
    return g_crc32_pmull;
}

const char *adf_kernels_backend(void) {
    switch (adf_kernels_isa()) {
        case ADF_ISA_X86_SSE2: return "sse2";
        case ADF_ISA_X86_SSE42: return "sse4.2";
        case ADF_ISA_X86_AVX2: return "avx2";
        case ADF_ISA_X86_AVX512: return "avx512";
        case ADF_ISA_ARM_NEON: return "neon";
        case ADF_ISA_ARM_DOTPROD: return "neon+dotprod";
        case ADF_ISA_ARM_I8MM: return "neon+i8mm";
        default: return "scalar";
    }
}

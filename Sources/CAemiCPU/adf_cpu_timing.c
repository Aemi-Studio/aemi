//
//  adf_cpu_timing.c
//  CAemiCPU
//
//  Data-independent timing for a thread, around code that handles secrets. Apart from the feature set so that
//  kernels without secrets (CAemiKernels) do not link Apple's `timingsafe` calls or the OS version check
//  `__builtin_available` makes, and stay within libc for Embedded consumers (Scripts/check-embedded.sh).
//

#include "CAemiCPU.h"

// Apple's `timingsafe` calls where the SDK has them: every device SDK does, no simulator SDK does (an arm64 simulator
// is `__APPLE__` and `__aarch64__` all the same), so a simulator takes the plain aarch64 DIT path below.
#if defined(__APPLE__) && defined(__aarch64__) && defined(__has_include)
#if __has_include(<timingsafe.h>)
#include <timingsafe.h>
#define ADF_HAS_TIMINGSAFE 1
#endif
#endif

#if defined(__aarch64__)
// PSTATE.DIT through its system-register name, so no assembler needs to know `dit`: bit 24.
#define ADF_DIT_BIT (UINT64_C(1) << 24)
static inline uint64_t adf_read_dit(void) {
    uint64_t value;
    __asm__ volatile("mrs %0, s3_3_c4_c2_5" : "=r"(value));
    return value & ADF_DIT_BIT;
}
static inline void adf_write_dit(uint64_t value) {
    __asm__ volatile("msr s3_3_c4_c2_5, %0" : : "r"(value) : "memory");
}
#endif

adf_timing_token_t adf_cpu_timing_safe_begin(void) {
#if defined(ADF_HAS_TIMINGSAFE)
    if (__builtin_available(macOS 15.2, iOS 18.2, tvOS 18.2, watchOS 11.2, visionOS 2.2, *)) {
        return timingsafe_enable_if_supported();
    }
#endif
#if defined(__aarch64__)
    if (adf_cpu_has(ADF_CPU_DIT)) {
        const uint64_t previous = adf_read_dit();
        adf_write_dit(ADF_DIT_BIT);
        return previous;
    }
#endif
    return 0;
}

void adf_cpu_timing_safe_end(adf_timing_token_t token) {
#if defined(ADF_HAS_TIMINGSAFE)
    if (__builtin_available(macOS 15.2, iOS 18.2, tvOS 18.2, watchOS 11.2, visionOS 2.2, *)) {
        timingsafe_restore_if_supported(token);
        return;
    }
#endif
#if defined(__aarch64__)
    if (adf_cpu_has(ADF_CPU_DIT)) {
        adf_write_dit(token & ADF_DIT_BIT);
    }
#else
    (void)token;
#endif
}

int adf_cpu_timing_safe_is_on(void) {
#if defined(__aarch64__)
    return adf_cpu_has(ADF_CPU_DIT) && adf_read_dit() != 0;
#else
    return 0;
#endif
}

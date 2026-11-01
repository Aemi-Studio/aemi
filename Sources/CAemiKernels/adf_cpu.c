//
//  adf_cpu.c
//  CAemiKernels
//
//  The byte kernels' ISA tier, read from CAemiCPU's feature set (resolved once there, shared with every C kernel of
//  the family). The tier is the widest ladder step this CPU has; dispatchers switch on it.
//

#include "CAemiKernels.h"

#include <CAemiCPU.h>

int adf_kernels_isa(void) {
#if defined(__x86_64__)
    // Under Rosetta 2 the tier is SSE4.2, or AVX2 when Rosetta advertises it (ROSETTA_ADVERTISE_AVX=1).
    if (adf_cpu_has(ADF_CPU_AVX512F | ADF_CPU_AVX512BW)) {
        return ADF_ISA_X86_AVX512;
    }
    if (adf_cpu_has(ADF_CPU_AVX2 | ADF_CPU_BMI2)) {
        return ADF_ISA_X86_AVX2;
    }
    return adf_cpu_has(ADF_CPU_SSE42) ? ADF_ISA_X86_SSE42 : ADF_ISA_X86_SSE2;
#elif defined(__aarch64__)
    // dotprod and i8mm are not implied by arm64 (M1 lacks i8mm), so they are asked.
    if (adf_cpu_has(ADF_CPU_I8MM)) {
        return ADF_ISA_ARM_I8MM;
    }
    return adf_cpu_has(ADF_CPU_DOTPROD) ? ADF_ISA_ARM_DOTPROD : ADF_ISA_ARM_NEON;
#else
    return ADF_ISA_SCALAR;
#endif
}

int adf_kernels_has_crc32_pmull(void) {
#if defined(__aarch64__)
    return adf_cpu_has(ADF_CPU_CRC32 | ADF_CPU_PMULL);
#else
    return 0;
#endif
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

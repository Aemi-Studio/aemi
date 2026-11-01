//
//  adf_crypto_cpu.c
//  CAemiArgon2
//
//  Which backends this CPU runs, from CAemiCPU's shared feature set: SHA3 is a compile-time constant on Apple silicon,
//  and AVX2 runs under Rosetta 2 when Rosetta advertises it.
//

#include "adf_argon2_internal.h"

#include <CAemiCPU.h>

static int adf_crypto_has(int backend) {
    switch (backend) {
    case ADF_CRYPTO_SCALAR: return 1;
#if defined(__aarch64__)
    case ADF_CRYPTO_NEON: return 1;
    case ADF_CRYPTO_NEON_SHA3: return ADF_CPU_HAS(SHA3);
#endif
#if defined(__x86_64__)
    case ADF_CRYPTO_SSSE3: return ADF_CPU_HAS(SSSE3);
    case ADF_CRYPTO_AVX2: return ADF_CPU_HAS(AVX2);
#endif
    default: return 0;
    }
}

int adf_crypto_resolve(int requested) {
    // From the best down: what FASTEST means, and where a named backend this CPU lacks falls to.
    static const int order[] = {ADF_CRYPTO_NEON_SHA3, ADF_CRYPTO_NEON, ADF_CRYPTO_AVX2, ADF_CRYPTO_SSSE3, ADF_CRYPTO_SCALAR};
    if (requested > ADF_CRYPTO_FASTEST && requested <= ADF_CRYPTO_AVX2 && adf_crypto_has(requested)) {
        return requested;
    }
    int below = requested == ADF_CRYPTO_FASTEST;
    for (size_t index = 0; index < sizeof order / sizeof order[0]; index++) {
        if (order[index] == requested) {
            below = 1;
        } else if (below && adf_crypto_has(order[index])) {
            return order[index];
        }
    }
    return ADF_CRYPTO_SCALAR;
}

const char *adf_crypto_backend_name(int backend) {
    switch (adf_crypto_resolve(backend)) {
    case ADF_CRYPTO_NEON: return "neon";
    case ADF_CRYPTO_NEON_SHA3: return "neon+sha3";
    case ADF_CRYPTO_SSSE3: return "ssse3";
    case ADF_CRYPTO_AVX2: return "avx2";
    default: return "scalar";
    }
}

adf_argon2_block_fn adf_argon2_block_function(int backend) {
    switch (adf_crypto_resolve(backend)) {
#if defined(__aarch64__)
    case ADF_CRYPTO_NEON: return adf_argon2_block_neon;
    case ADF_CRYPTO_NEON_SHA3: return adf_argon2_block_neon_sha3;
#endif
#if defined(__x86_64__)
    case ADF_CRYPTO_SSSE3: return adf_argon2_block_ssse3;
    case ADF_CRYPTO_AVX2: return adf_argon2_block_avx2;
#endif
    default: return adf_argon2_block_scalar;
    }
}

void adf_argon2_block(uint64_t *next, const uint64_t *prev, const uint64_t *ref, int with_xor, int backend) {
    const adf_timing_token_t token = adf_cpu_timing_safe_begin();
    adf_argon2_block_function(backend)(next, prev, ref, with_xor);
    adf_cpu_timing_safe_end(token);
}

void adf_blake2b_compress(uint64_t state[8], const uint64_t block[16], uint64_t count_low, uint64_t count_high,
                          int last, int backend) {
    const adf_timing_token_t token = adf_cpu_timing_safe_begin();
    switch (adf_crypto_resolve(backend)) {
#if defined(__aarch64__)
    case ADF_CRYPTO_NEON: adf_blake2b_compress_neon(state, block, count_low, count_high, last, 0); break;
    case ADF_CRYPTO_NEON_SHA3: adf_blake2b_compress_neon(state, block, count_low, count_high, last, 1); break;
#endif
    default: adf_blake2b_compress_scalar(state, block, count_low, count_high, last); break;
    }
    adf_cpu_timing_safe_end(token);
}

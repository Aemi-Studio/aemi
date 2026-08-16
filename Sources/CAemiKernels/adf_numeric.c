//
//  adf_numeric.c
//  CAemiKernels
//
//  Non-byte-scan numeric kernels. `adf_hamming_distance` is the bit-vector similarity primitive the
//  semantic-search tier's KNN scan runs once per corpus vector per query: XOR two packed bit vectors
//  and sum the set bits. On arm64 a NEON `cnt` (population count per byte, 16 bytes/instr) + a
//  widening pairwise add is ~2–4× the scalar 5-op SWAR; on x86-64 and the fallback, the compiler's
//  `__builtin_popcountll` lowers to the hardware `POPCNT`. The result is an EXACT integer, identical
//  on every backend (popcount is additive over the XOR), so `hammingDistanceLUT` remains the oracle.
//

#include "CAemiKernels.h"

#if defined(__aarch64__)
#include <arm_neon.h>
#endif

size_t adf_hamming_distance_scalar(const uint8_t *a, const uint8_t *b, size_t len) {
    size_t total = 0;
    size_t i = 0;
    for (; i + 8 <= len; i += 8) {
        uint64_t wa, wb;
        __builtin_memcpy(&wa, a + i, 8);
        __builtin_memcpy(&wb, b + i, 8);
        total += (size_t)__builtin_popcountll(wa ^ wb);
    }
    for (; i < len; ++i) {
        total += (size_t)__builtin_popcount((unsigned)(uint8_t)(a[i] ^ b[i]));
    }
    return total;
}

#if defined(__aarch64__)
static size_t adf_hamming_neon(const uint8_t *a, const uint8_t *b, size_t len) {
    size_t total = 0;
    size_t i = 0;
    // `cnt` (per-byte popcount) accumulated with ONE widening pairwise-add (`vpadalq_u8`) per 16 bytes;
    // flushed to a scalar before the u16 lanes could overflow (2048 blocks × 16 = 32768 < 65535).
    while (i + 16 <= len) {
        size_t blockEnd = i + 2048 * 16;
        if (blockEnd > len) {
            blockEnd = len;
        }
        uint16x8_t acc = vdupq_n_u16(0);
        for (; i + 16 <= blockEnd; i += 16) {
            uint8x16_t x = veorq_u8(vld1q_u8(a + i), vld1q_u8(b + i));
            acc = vpadalq_u8(acc, vcntq_u8(x));
        }
        total += (size_t)vaddvq_u16(acc);
    }
    for (; i < len; ++i) {
        total += (size_t)__builtin_popcount((unsigned)(uint8_t)(a[i] ^ b[i]));
    }
    return total;
}
#endif  // __aarch64__

size_t adf_hamming_distance(const uint8_t *a, const uint8_t *b, size_t len) {
#if defined(__aarch64__)
    // Small widths (e.g. 64-byte embeddings) are faster on the POPCNT-lowered scalar path than on a
    // single-pair NEON call (whose horizontal reduction + dispatch don't amortize); NEON wins on long
    // bit-vectors. The BATCHED `adf_hamming_scan` is the right primitive for scanning many small ones.
    if (len >= 256 && adf_kernels_isa() >= ADF_ISA_ARM_NEON) {
        return adf_hamming_neon(a, b, len);
    }
#endif
    return adf_hamming_distance_scalar(a, b, len);
}

void adf_hamming_scan(
    const uint8_t *query, const uint8_t *corpus, size_t width, size_t count, uint32_t *out) {
#if defined(__aarch64__)
    if (width >= 16 && adf_kernels_isa() >= ADF_ISA_ARM_NEON) {
        for (size_t v = 0; v < count; ++v) {
            const uint8_t *vec = corpus + v * width;
            uint16x8_t acc = vdupq_n_u16(0);
            size_t i = 0;
            for (; i + 16 <= width; i += 16) {
                uint8x16_t x = veorq_u8(vld1q_u8(query + i), vld1q_u8(vec + i));
                acc = vpadalq_u8(acc, vcntq_u8(x));
            }
            size_t total = (size_t)vaddvq_u16(acc);
            for (; i < width; ++i) {
                total += (size_t)__builtin_popcount((unsigned)(uint8_t)(query[i] ^ vec[i]));
            }
            out[v] = (uint32_t)total;
        }
        return;
    }
#endif
    for (size_t v = 0; v < count; ++v) {
        out[v] = (uint32_t)adf_hamming_distance_scalar(query, corpus + v * width, width);
    }
}

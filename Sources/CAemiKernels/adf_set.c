//
//  adf_set.c
//  CAemiKernels
//
//  First byte of a set, the set given as two nibble tables: `b` is in the set iff `lo[b & 15] & hi[b >> 4]` is nonzero.
//  On arm64 each table is one `tbl` lookup (adf_neon_scan.h supplies the loop, the 64-byte step, the overlapping tail and the mask
//  that locates the hit); on x86-64 with SSSE3 `pshufb` does the same. Every backend agrees with the scalar reference.
//

#include "CAemiKernels.h"
#include "adf_neon_scan.h"

#if defined(__x86_64__)
#include <immintrin.h>
#endif

size_t adf_index_of_set_scalar(const uint8_t *buf, size_t len, const uint8_t lo[16], const uint8_t hi[16]) {
    for (size_t i = 0; i < len; ++i) {
        if (lo[buf[i] & 15] & hi[buf[i] >> 4]) {
            return i;
        }
    }
    return len;
}

#if defined(__aarch64__)
typedef struct {
    uint8x16_t lo, hi;
    const uint8_t *loBytes, *hiBytes;
} set_ctx;

__attribute__((always_inline)) static inline uint8x16_t set_classify(uint8x16_t v, const void *ctx) {
    const set_ctx *c = (const set_ctx *)ctx;
    const uint8x16_t low = vqtbl1q_u8(c->lo, vandq_u8(v, vdupq_n_u8(0x0F)));
    const uint8x16_t high = vqtbl1q_u8(c->hi, vshrq_n_u8(v, 4));
    return vtstq_u8(low, high);  // 0xFF where the two share a bit
}

__attribute__((always_inline)) static inline size_t set_scalar(const uint8_t *buf, size_t len, const void *ctx) {
    const set_ctx *c = (const set_ctx *)ctx;
    return adf_index_of_set_scalar(buf, len, c->loBytes, c->hiBytes);
}

static size_t set_neon_impl(const uint8_t *buf, size_t len, const uint8_t lo[16], const uint8_t hi[16]) {
    const set_ctx ctx = {vld1q_u8(lo), vld1q_u8(hi), lo, hi};
    return adf_neon_scan(buf, len, set_classify, set_scalar, &ctx);
}
#endif

#if defined(__x86_64__)
__attribute__((target("ssse3")))
static size_t set_ssse3_impl(const uint8_t *buf, size_t len, const uint8_t lo[16], const uint8_t hi[16]) {
    const __m128i vLo = _mm_loadu_si128((const __m128i *)lo), vHi = _mm_loadu_si128((const __m128i *)hi);
    const __m128i nibble = _mm_set1_epi8(0x0F);
    size_t i = 0;
    for (; i + 16 <= len; i += 16) {
        __m128i v = _mm_loadu_si128((const __m128i *)(buf + i));
        __m128i low = _mm_shuffle_epi8(vLo, _mm_and_si128(v, nibble));
        __m128i high = _mm_shuffle_epi8(vHi, _mm_and_si128(_mm_srli_epi16(v, 4), nibble));
        __m128i both = _mm_and_si128(low, high);
        int mask = ~_mm_movemask_epi8(_mm_cmpeq_epi8(both, _mm_setzero_si128())) & 0xFFFF;
        if (mask != 0) {
            return i + (size_t)__builtin_ctz((unsigned)mask);
        }
    }
    if (i < len) {
        size_t r = adf_index_of_set_scalar(buf + i, len - i, lo, hi);
        return (r == len - i) ? len : i + r;
    }
    return len;
}
#endif

size_t adf_index_of_set(const uint8_t *buf, size_t len, const uint8_t lo[16], const uint8_t hi[16]) {
#if defined(__aarch64__)
    // NEON is mandatory on arm64: nothing to look up (ADR-0014).
    return set_neon_impl(buf, len, lo, hi);
#elif defined(__x86_64__)
    if (adf_kernels_isa() >= ADF_ISA_X86_SSE42) {  // SSE4.2 implies SSSE3
        return set_ssse3_impl(buf, len, lo, hi);
    }
    return adf_index_of_set_scalar(buf, len, lo, hi);
#else
    return adf_index_of_set_scalar(buf, len, lo, hi);
#endif
}

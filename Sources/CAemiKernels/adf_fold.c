//
//  adf_fold.c
//  CAemiKernels
//
//  ASCII case-fold (A–Z → a–z), leaving every other byte untouched. Branchless SIMD: subtract 'A',
//  a saturating-unsigned compare against 25 selects the A–Z lanes, then OR in 0x20. Baseline SSE2 /
//  NEON (always present) plus an AVX2 widening; the tail and other arches use the scalar reference.
//

#include "CAemiKernels.h"

#if defined(__x86_64__)
#include <immintrin.h>
#elif defined(__aarch64__)
#include <arm_neon.h>
#endif

// MARK: - Scalar reference (the differential-test oracle)

void adf_fold_ascii_scalar(uint8_t *dst, const uint8_t *src, size_t len) {
    for (size_t i = 0; i < len; ++i) {
        uint8_t b = src[i];
        dst[i] = (b >= 0x41 && b <= 0x5A) ? (uint8_t)(b | 0x20) : b;
    }
}

// MARK: - x86-64 implementations

#if defined(__x86_64__)
static void fold_sse2_impl(uint8_t *dst, const uint8_t *src, size_t len) {
    const __m128i vA = _mm_set1_epi8(0x41);   // 'A'
    const __m128i vLim = _mm_set1_epi8(25);   // 'Z' - 'A'
    const __m128i vLow = _mm_set1_epi8(0x20);
    const __m128i vZero = _mm_setzero_si128();
    size_t i = 0;
    for (; i + 16 <= len; i += 16) {
        __m128i v = _mm_loadu_si128((const __m128i *)(src + i));
        __m128i sub = _mm_sub_epi8(v, vA);                                // b - 'A' (wraps if b < 'A')
        __m128i isUpper = _mm_cmpeq_epi8(_mm_subs_epu8(sub, vLim), vZero);  // sub <= 25 ⇒ 0xFF
        v = _mm_or_si128(v, _mm_and_si128(isUpper, vLow));
        _mm_storeu_si128((__m128i *)(dst + i), v);
    }
    if (i < len) {
        adf_fold_ascii_scalar(dst + i, src + i, len - i);
    }
}

__attribute__((target("avx2")))
static void fold_avx2_impl(uint8_t *dst, const uint8_t *src, size_t len) {
    const __m256i vA = _mm256_set1_epi8(0x41);
    const __m256i vLim = _mm256_set1_epi8(25);
    const __m256i vLow = _mm256_set1_epi8(0x20);
    const __m256i vZero = _mm256_setzero_si256();
    size_t i = 0;
    for (; i + 32 <= len; i += 32) {
        __m256i v = _mm256_loadu_si256((const __m256i *)(src + i));
        __m256i sub = _mm256_sub_epi8(v, vA);
        __m256i isUpper = _mm256_cmpeq_epi8(_mm256_subs_epu8(sub, vLim), vZero);
        v = _mm256_or_si256(v, _mm256_and_si256(isUpper, vLow));
        _mm256_storeu_si256((__m256i *)(dst + i), v);
    }
    // Scalar tail (< 32 bytes) — integer code, so no AVX↔SSE transition to guard against.
    if (i < len) {
        adf_fold_ascii_scalar(dst + i, src + i, len - i);
    }
}
#endif  // __x86_64__

// MARK: - arm64 implementation

#if defined(__aarch64__)
static void fold_neon_impl(uint8_t *dst, const uint8_t *src, size_t len) {
    const uint8x16_t vA = vdupq_n_u8(0x41);
    const uint8x16_t vLim = vdupq_n_u8(25);
    const uint8x16_t vLow = vdupq_n_u8(0x20);
    const uint8x16_t vZero = vdupq_n_u8(0);
    size_t i = 0;
    for (; i + 16 <= len; i += 16) {
        uint8x16_t v = vld1q_u8(src + i);
        uint8x16_t sub = vsubq_u8(v, vA);
        uint8x16_t isUpper = vceqq_u8(vqsubq_u8(sub, vLim), vZero);  // sub <= 25 ⇒ 0xFF
        v = vorrq_u8(v, vandq_u8(isUpper, vLow));
        vst1q_u8(dst + i, v);
    }
    if (i < len) {
        adf_fold_ascii_scalar(dst + i, src + i, len - i);
    }
}
#endif  // __aarch64__

// MARK: - Named backends (self-guarding) + best-available dispatcher

void adf_fold_ascii_sse2(uint8_t *dst, const uint8_t *src, size_t len) {
#if defined(__x86_64__)
    fold_sse2_impl(dst, src, len);  // SSE2 is the x86-64 baseline — always safe.
#else
    adf_fold_ascii_scalar(dst, src, len);
#endif
}

void adf_fold_ascii_avx2(uint8_t *dst, const uint8_t *src, size_t len) {
#if defined(__x86_64__)
    if (adf_kernels_isa() >= ADF_ISA_X86_AVX2) {
        fold_avx2_impl(dst, src, len);
        return;
    }
    fold_sse2_impl(dst, src, len);
#else
    adf_fold_ascii_scalar(dst, src, len);
#endif
}

void adf_fold_ascii_neon(uint8_t *dst, const uint8_t *src, size_t len) {
#if defined(__aarch64__)
    fold_neon_impl(dst, src, len);  // NEON is the arm64 baseline — always safe.
#else
    adf_fold_ascii_scalar(dst, src, len);
#endif
}

void adf_fold_ascii(uint8_t *dst, const uint8_t *src, size_t len) {
    switch (adf_kernels_isa()) {
#if defined(__x86_64__)
        case ADF_ISA_X86_AVX512:
        case ADF_ISA_X86_AVX2:
            fold_avx2_impl(dst, src, len);
            return;
        case ADF_ISA_X86_SSE42:
        case ADF_ISA_X86_SSE2:
            fold_sse2_impl(dst, src, len);
            return;
#elif defined(__aarch64__)
        case ADF_ISA_ARM_I8MM:
        case ADF_ISA_ARM_DOTPROD:
        case ADF_ISA_ARM_NEON:
            fold_neon_impl(dst, src, len);
            return;
#endif
        default:
            adf_fold_ascii_scalar(dst, src, len);
            return;
    }
}

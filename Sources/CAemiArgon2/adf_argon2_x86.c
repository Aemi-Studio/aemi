//
//  adf_argon2_x86.c
//  CAemiArgon2
//
//  G on x86-64. SSSE3: two words per register, as on NEON, `palignr` for the diagonal, `pshufb` for the rotations by 24
//  and 16, `pmuludq` for BlaMka's product. AVX2: four words per register, so a P is four registers and its diagonal step
//  three `vpermq`. Each function is compiled for its own target, and only called once CPUID has said the CPU has it.
//

#include "adf_argon2_internal.h"

#if defined(__x86_64__)
#include <immintrin.h>

// MARK: - SSSE3

#define ADF_SSSE3 __attribute__((target("ssse3")))

ADF_SSSE3 static inline __m128i adf_ssse3_blamka(__m128i x, __m128i y) {
    const __m128i product = _mm_mul_epu32(x, y);
    return _mm_add_epi64(_mm_add_epi64(x, y), _mm_add_epi64(product, product));
}

ADF_SSSE3 static inline __m128i adf_ssse3_xor_rotr(__m128i x, __m128i y, int n) {
    const __m128i v = _mm_xor_si128(x, y);
    switch (n) {
    case 32: return _mm_shuffle_epi32(v, _MM_SHUFFLE(2, 3, 0, 1));
    case 24: return _mm_shuffle_epi8(v, _mm_setr_epi8(3, 4, 5, 6, 7, 0, 1, 2, 11, 12, 13, 14, 15, 8, 9, 10));
    case 16: return _mm_shuffle_epi8(v, _mm_setr_epi8(2, 3, 4, 5, 6, 7, 0, 1, 10, 11, 12, 13, 14, 15, 8, 9));
    default: return _mm_xor_si128(_mm_srli_epi64(v, 63), _mm_add_epi64(v, v));
    }
}

#define ADF_SSSE3_GB2(a0, b0, c0, d0, a1, b1, c1, d1)                                                                  \
    do {                                                                                                               \
        a0 = adf_ssse3_blamka(a0, b0);                                                                                 \
        a1 = adf_ssse3_blamka(a1, b1);                                                                                 \
        d0 = adf_ssse3_xor_rotr(d0, a0, 32);                                                                           \
        d1 = adf_ssse3_xor_rotr(d1, a1, 32);                                                                           \
        c0 = adf_ssse3_blamka(c0, d0);                                                                                 \
        c1 = adf_ssse3_blamka(c1, d1);                                                                                 \
        b0 = adf_ssse3_xor_rotr(b0, c0, 24);                                                                           \
        b1 = adf_ssse3_xor_rotr(b1, c1, 24);                                                                           \
        a0 = adf_ssse3_blamka(a0, b0);                                                                                 \
        a1 = adf_ssse3_blamka(a1, b1);                                                                                 \
        d0 = adf_ssse3_xor_rotr(d0, a0, 16);                                                                           \
        d1 = adf_ssse3_xor_rotr(d1, a1, 16);                                                                           \
        c0 = adf_ssse3_blamka(c0, d0);                                                                                 \
        c1 = adf_ssse3_blamka(c1, d1);                                                                                 \
        b0 = adf_ssse3_xor_rotr(b0, c0, 63);                                                                           \
        b1 = adf_ssse3_xor_rotr(b1, c1, 63);                                                                           \
    } while (0)

ADF_SSSE3 static inline void adf_ssse3_p(__m128i *r0, __m128i *r1, __m128i *r2, __m128i *r3, __m128i *r4,
                                         __m128i *r5, __m128i *r6, __m128i *r7) {
    ADF_SSSE3_GB2(*r0, *r2, *r4, *r6, *r1, *r3, *r5, *r7);
    // _mm_alignr_epi8(hi, lo, 8) = (lo[1], hi[0]), NEON's vextq_u64(lo, hi, 1).
    __m128i b0 = _mm_alignr_epi8(*r3, *r2, 8), b1 = _mm_alignr_epi8(*r2, *r3, 8);
    __m128i c0 = *r5, c1 = *r4;
    __m128i d0 = _mm_alignr_epi8(*r6, *r7, 8), d1 = _mm_alignr_epi8(*r7, *r6, 8);
    ADF_SSSE3_GB2(*r0, b0, c0, d0, *r1, b1, c1, d1);
    *r2 = _mm_alignr_epi8(b0, b1, 8);
    *r3 = _mm_alignr_epi8(b1, b0, 8);
    *r4 = c1;
    *r5 = c0;
    *r6 = _mm_alignr_epi8(d1, d0, 8);
    *r7 = _mm_alignr_epi8(d0, d1, 8);
}

ADF_SSSE3
void adf_argon2_block_ssse3(uint64_t *next, const uint64_t *prev, const uint64_t *ref, int with_xor) {
    __m128i r[64], z[64];
    for (size_t index = 0; index < 64; index++) {
        r[index] = _mm_xor_si128(_mm_loadu_si128((const __m128i *)(const void *)(prev + 2 * index)),
                                 _mm_loadu_si128((const __m128i *)(const void *)(ref + 2 * index)));
        z[index] = r[index];
    }
    for (size_t row = 0; row < 8; row++) {
        __m128i *q = z + 8 * row;
        adf_ssse3_p(q, q + 1, q + 2, q + 3, q + 4, q + 5, q + 6, q + 7);
    }
    for (size_t column = 0; column < 8; column++) {
        __m128i *q = z + column;
        adf_ssse3_p(q, q + 8, q + 16, q + 24, q + 32, q + 40, q + 48, q + 56);
    }
    for (size_t index = 0; index < 64; index++) {
        __m128i *out = (__m128i *)(void *)(next + 2 * index);
        __m128i value = _mm_xor_si128(z[index], r[index]);
        if (with_xor) {
            value = _mm_xor_si128(value, _mm_loadu_si128(out));
        }
        _mm_storeu_si128(out, value);
    }
}

// MARK: - AVX2

#define ADF_AVX2 __attribute__((target("avx2")))

ADF_AVX2 static inline __m256i adf_avx2_blamka(__m256i x, __m256i y) {
    const __m256i product = _mm256_mul_epu32(x, y);
    return _mm256_add_epi64(_mm256_add_epi64(x, y), _mm256_add_epi64(product, product));
}

ADF_AVX2 static inline __m256i adf_avx2_xor_rotr(__m256i x, __m256i y, int n) {
    const __m256i v = _mm256_xor_si256(x, y);
    switch (n) {
    case 32: return _mm256_shuffle_epi32(v, _MM_SHUFFLE(2, 3, 0, 1));
    case 24:
        return _mm256_shuffle_epi8(v, _mm256_setr_epi8(3, 4, 5, 6, 7, 0, 1, 2, 11, 12, 13, 14, 15, 8, 9, 10, 3, 4, 5,
                                                       6, 7, 0, 1, 2, 11, 12, 13, 14, 15, 8, 9, 10));
    case 16:
        return _mm256_shuffle_epi8(v, _mm256_setr_epi8(2, 3, 4, 5, 6, 7, 0, 1, 10, 11, 12, 13, 14, 15, 8, 9, 2, 3, 4,
                                                       5, 6, 7, 0, 1, 10, 11, 12, 13, 14, 15, 8, 9));
    default: return _mm256_xor_si256(_mm256_srli_epi64(v, 63), _mm256_add_epi64(v, v));
    }
}

ADF_AVX2 static inline void adf_avx2_gb(__m256i *a, __m256i *b, __m256i *c, __m256i *d) {
    *a = adf_avx2_blamka(*a, *b);
    *d = adf_avx2_xor_rotr(*d, *a, 32);
    *c = adf_avx2_blamka(*c, *d);
    *b = adf_avx2_xor_rotr(*b, *c, 24);
    *a = adf_avx2_blamka(*a, *b);
    *d = adf_avx2_xor_rotr(*d, *a, 16);
    *c = adf_avx2_blamka(*c, *d);
    *b = adf_avx2_xor_rotr(*b, *c, 63);
}

/// P with a = words 0-3, b = 4-7, c = 8-11, d = 12-15: columns, then the diagonals by rotating b, c and d's lanes.
ADF_AVX2 static inline void adf_avx2_p(__m256i *a, __m256i *b, __m256i *c, __m256i *d) {
    adf_avx2_gb(a, b, c, d);
    *b = _mm256_permute4x64_epi64(*b, _MM_SHUFFLE(0, 3, 2, 1));
    *c = _mm256_permute4x64_epi64(*c, _MM_SHUFFLE(1, 0, 3, 2));
    *d = _mm256_permute4x64_epi64(*d, _MM_SHUFFLE(2, 1, 0, 3));
    adf_avx2_gb(a, b, c, d);
    *b = _mm256_permute4x64_epi64(*b, _MM_SHUFFLE(2, 1, 0, 3));
    *c = _mm256_permute4x64_epi64(*c, _MM_SHUFFLE(1, 0, 3, 2));
    *d = _mm256_permute4x64_epi64(*d, _MM_SHUFFLE(0, 3, 2, 1));
}

ADF_AVX2 static inline __m256i adf_avx2_two_pairs(const uint64_t *z, size_t first, size_t second) {
    return _mm256_loadu2_m128i((const __m128i *)(const void *)(z + second), (const __m128i *)(const void *)(z + first));
}

ADF_AVX2 static inline void adf_avx2_store_pairs(uint64_t *z, size_t first, size_t second, __m256i v) {
    _mm256_storeu2_m128i((__m128i *)(void *)(z + second), (__m128i *)(void *)(z + first), v);
}

ADF_AVX2
void adf_argon2_block_avx2(uint64_t *next, const uint64_t *prev, const uint64_t *ref, int with_xor) {
    uint64_t r[128] __attribute__((aligned(32))), z[128] __attribute__((aligned(32)));
    for (size_t index = 0; index < 128; index += 4) {
        const __m256i v = _mm256_xor_si256(_mm256_loadu_si256((const __m256i *)(const void *)(prev + index)),
                                           _mm256_loadu_si256((const __m256i *)(const void *)(ref + index)));
        _mm256_store_si256((__m256i *)(void *)(r + index), v);
        _mm256_store_si256((__m256i *)(void *)(z + index), v);
    }
    for (size_t row = 0; row < 8; row++) {
        __m256i *q = (__m256i *)(void *)(z + 16 * row);
        __m256i a = q[0], b = q[1], c = q[2], d = q[3];
        adf_avx2_p(&a, &b, &c, &d);
        q[0] = a, q[1] = b, q[2] = c, q[3] = d;
    }
    for (size_t column = 0; column < 8; column++) {
        // Column `column`'s sixteen words: the pair at 2 * column of each row, rows 0 to 7.
        const size_t base = 2 * column;
        __m256i a = adf_avx2_two_pairs(z, base, base + 16), b = adf_avx2_two_pairs(z, base + 32, base + 48);
        __m256i c = adf_avx2_two_pairs(z, base + 64, base + 80), d = adf_avx2_two_pairs(z, base + 96, base + 112);
        adf_avx2_p(&a, &b, &c, &d);
        adf_avx2_store_pairs(z, base, base + 16, a);
        adf_avx2_store_pairs(z, base + 32, base + 48, b);
        adf_avx2_store_pairs(z, base + 64, base + 80, c);
        adf_avx2_store_pairs(z, base + 96, base + 112, d);
    }
    for (size_t index = 0; index < 128; index += 4) {
        __m256i *out = (__m256i *)(void *)(next + index);
        __m256i value = _mm256_xor_si256(_mm256_load_si256((const __m256i *)(const void *)(z + index)),
                                         _mm256_load_si256((const __m256i *)(const void *)(r + index)));
        if (with_xor) {
            value = _mm256_xor_si256(value, _mm256_loadu_si256(out));
        }
        _mm256_storeu_si256(out, value);
    }
}

#endif

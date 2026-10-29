//
//  adf_teddy.c
//  CAemiKernels
//
//  First position of any of a set of byte pairs: a two-byte Teddy kernel, promoted from AemiRegex (aemi ADR 0018).
//
//  Each pair goes to a bucket (0 to 7). For each of the two byte positions there are two 16-entry tables, indexed by the low and by
//  the high nibble of the byte; an entry holds the buckets that accept that nibble. A byte is accepted by a bucket when both of its
//  nibble entries have the bucket's bit, and a position is a candidate when the first byte and the second byte share a bucket: the
//  two-position form of adf_set.c's one-position set. The nibble lookup is `tbl` on NEON and `pshufb` on x86-64 with SSSE3.
//
//  Memory safety: a vector load at `hay + i` happens only when `i + 16 <= len`; the load at `hay + i + 1` only when `i + 17 <= len`
//  (the 64-byte loop requires `i + 65 <= len`). The tail is scalar. No read passes `hay + len`.
//

#include "CAemiKernels.h"

#if defined(__aarch64__)
#include <arm_neon.h>
#elif defined(__x86_64__)
#include <immintrin.h>
#endif

static inline int candidate_scalar(const uint8_t *t, uint8_t a, uint8_t b) {
    return (t[a & 15] & t[16 + (a >> 4)] & t[32 + (b & 15)] & t[48 + (b >> 4)]) != 0;
}

size_t adf_pair_set_find_scalar(const uint8_t *t, const uint8_t *h, size_t len, size_t from) {
    for (size_t i = from; i + 1 < len; i++) {
        if (candidate_scalar(t, h[i], h[i + 1])) return i;
    }
    return SIZE_MAX;
}

#if defined(__aarch64__)

typedef struct { uint8x16_t lo0, hi0, lo1, hi1, mask; } neon_tables;

static inline uint8x16_t candidates_neon(const neon_tables *t, const uint8_t *p) {
    uint8x16_t v0 = vld1q_u8(p), v1 = vld1q_u8(p + 1);
    uint8x16_t r0 = vandq_u8(vqtbl1q_u8(t->lo0, vandq_u8(v0, t->mask)), vqtbl1q_u8(t->hi0, vshrq_n_u8(v0, 4)));
    uint8x16_t r1 = vandq_u8(vqtbl1q_u8(t->lo1, vandq_u8(v1, t->mask)), vqtbl1q_u8(t->hi1, vshrq_n_u8(v1, 4)));
    return vandq_u8(r0, r1);
}

/// The index of the first nonzero lane. NEON has no movemask, so the lanes narrow to a nibble each in one 64-bit word.
static inline size_t first_lane(uint8x16_t c) {
    uint8x16_t nonzero = vtstq_u8(c, c);
    uint64_t bits = vget_lane_u64(vreinterpret_u64_u8(vshrn_n_u16(vreinterpretq_u16_u8(nonzero), 4)), 0);
    return (size_t)(__builtin_ctzll(bits) >> 2);
}

static size_t find_neon(const uint8_t *table, const uint8_t *h, size_t len, size_t from) {
    neon_tables t = {vld1q_u8(table), vld1q_u8(table + 16), vld1q_u8(table + 32), vld1q_u8(table + 48), vdupq_n_u8(15)};
    size_t i = from;
    while (i + 65 <= len) {
        uint8x16_t c0 = candidates_neon(&t, h + i), c1 = candidates_neon(&t, h + i + 16);
        uint8x16_t c2 = candidates_neon(&t, h + i + 32), c3 = candidates_neon(&t, h + i + 48);
        if (vmaxvq_u8(vorrq_u8(vorrq_u8(c0, c1), vorrq_u8(c2, c3))) != 0) {
            if (vmaxvq_u8(c0) != 0) return i + first_lane(c0);
            if (vmaxvq_u8(c1) != 0) return i + 16 + first_lane(c1);
            if (vmaxvq_u8(c2) != 0) return i + 32 + first_lane(c2);
            return i + 48 + first_lane(c3);
        }
        i += 64;
    }
    while (i + 17 <= len) {
        uint8x16_t c = candidates_neon(&t, h + i);
        if (vmaxvq_u8(c) != 0) return i + first_lane(c);
        i += 16;
    }
    return adf_pair_set_find_scalar(table, h, len, i);
}

#elif defined(__x86_64__)

__attribute__((target("ssse3"))) static inline __m128i candidates_ssse3(
    __m128i lo0, __m128i hi0, __m128i lo1, __m128i hi1, __m128i mask, const uint8_t *p) {
    __m128i v0 = _mm_loadu_si128((const __m128i *)p), v1 = _mm_loadu_si128((const __m128i *)(p + 1));
    __m128i r0 = _mm_and_si128(_mm_shuffle_epi8(lo0, _mm_and_si128(v0, mask)),
                               _mm_shuffle_epi8(hi0, _mm_and_si128(_mm_srli_epi16(v0, 4), mask)));
    __m128i r1 = _mm_and_si128(_mm_shuffle_epi8(lo1, _mm_and_si128(v1, mask)),
                               _mm_shuffle_epi8(hi1, _mm_and_si128(_mm_srli_epi16(v1, 4), mask)));
    return _mm_and_si128(r0, r1);
}

/// The 16-bit mask of nonzero lanes.
__attribute__((target("ssse3"))) static inline unsigned nonzero_lanes(__m128i c) {
    return (~(unsigned)_mm_movemask_epi8(_mm_cmpeq_epi8(c, _mm_setzero_si128()))) & 0xFFFFu;
}

__attribute__((target("ssse3"))) static size_t find_ssse3(const uint8_t *table, const uint8_t *h, size_t len, size_t from) {
    __m128i lo0 = _mm_loadu_si128((const __m128i *)table), hi0 = _mm_loadu_si128((const __m128i *)(table + 16));
    __m128i lo1 = _mm_loadu_si128((const __m128i *)(table + 32)), hi1 = _mm_loadu_si128((const __m128i *)(table + 48));
    __m128i mask = _mm_set1_epi8(15);
    size_t i = from;
    while (i + 65 <= len) {
        __m128i c0 = candidates_ssse3(lo0, hi0, lo1, hi1, mask, h + i);
        __m128i c1 = candidates_ssse3(lo0, hi0, lo1, hi1, mask, h + i + 16);
        __m128i c2 = candidates_ssse3(lo0, hi0, lo1, hi1, mask, h + i + 32);
        __m128i c3 = candidates_ssse3(lo0, hi0, lo1, hi1, mask, h + i + 48);
        unsigned m0 = nonzero_lanes(c0), m1 = nonzero_lanes(c1), m2 = nonzero_lanes(c2), m3 = nonzero_lanes(c3);
        if (m0 | m1 | m2 | m3) {
            if (m0) return i + (size_t)__builtin_ctz(m0);
            if (m1) return i + 16 + (size_t)__builtin_ctz(m1);
            if (m2) return i + 32 + (size_t)__builtin_ctz(m2);
            return i + 48 + (size_t)__builtin_ctz(m3);
        }
        i += 64;
    }
    while (i + 17 <= len) {
        unsigned m = nonzero_lanes(candidates_ssse3(lo0, hi0, lo1, hi1, mask, h + i));
        if (m) return i + (size_t)__builtin_ctz(m);
        i += 16;
    }
    return adf_pair_set_find_scalar(table, h, len, i);
}

#endif

/// The scalar part of a batch: candidates one byte at a time from `i`, until `cap` is reached or the text ends.
static size_t candidates_scalar(
    const uint8_t *t, const uint8_t *h, size_t len, size_t i, size_t *out, size_t n, size_t cap, size_t *resume) {
    for (; i + 1 < len; i++) {
        if (n == cap) { *resume = i; return n; }
        if (candidate_scalar(t, h[i], h[i + 1])) out[n++] = i;
    }
    *resume = len;
    return n;
}

#if defined(__aarch64__)

/// Appends the lanes of `c` that hold a candidate, as `base + lane`, in ascending order.
static inline size_t emit_neon(uint8x16_t c, size_t base, size_t *out, size_t n) {
    uint64_t bits = vget_lane_u64(vreinterpret_u64_u8(vshrn_n_u16(vreinterpretq_u16_u8(vtstq_u8(c, c)), 4)), 0);
    while (bits) {
        unsigned lane = (unsigned)(__builtin_ctzll(bits) >> 2);
        out[n++] = base + lane;
        bits &= ~(0xFull << (lane * 4));
    }
    return n;
}

static size_t candidates_neon_batch(
    const uint8_t *table, const uint8_t *h, size_t len, size_t from, size_t *out, size_t cap, size_t *resume) {
    neon_tables t = {vld1q_u8(table), vld1q_u8(table + 16), vld1q_u8(table + 32), vld1q_u8(table + 48), vdupq_n_u8(15)};
    size_t i = from, n = 0;
    // `n + 64 <= cap` (or `n + 16 <= cap`) before a step guarantees room for every lane that step can write.
    while (i + 17 <= len && n + 16 <= cap) {
        if (i + 65 <= len && n + 64 <= cap) {
            uint8x16_t c0 = candidates_neon(&t, h + i), c1 = candidates_neon(&t, h + i + 16);
            uint8x16_t c2 = candidates_neon(&t, h + i + 32), c3 = candidates_neon(&t, h + i + 48);
            if (vmaxvq_u8(vorrq_u8(vorrq_u8(c0, c1), vorrq_u8(c2, c3))) != 0) {
                n = emit_neon(c0, i, out, n);
                n = emit_neon(c1, i + 16, out, n);
                n = emit_neon(c2, i + 32, out, n);
                n = emit_neon(c3, i + 48, out, n);
            }
            i += 64;
            continue;
        }
        uint8x16_t c = candidates_neon(&t, h + i);
        if (vmaxvq_u8(c) != 0) n = emit_neon(c, i, out, n);
        i += 16;
    }
    if (i + 17 <= len) { *resume = i; return n; }  // stopped for room, not for the end
    return candidates_scalar(table, h, len, i, out, n, cap, resume);
}

#elif defined(__x86_64__)

/// Appends the lanes of the 16-bit mask `bits` as `base + lane`, in ascending order.
__attribute__((target("ssse3"))) static inline size_t emit_ssse3(unsigned bits, size_t base, size_t *out, size_t n) {
    while (bits) {
        out[n++] = base + (size_t)__builtin_ctz(bits);
        bits &= bits - 1;
    }
    return n;
}

__attribute__((target("ssse3"))) static size_t candidates_ssse3_batch(
    const uint8_t *table, const uint8_t *h, size_t len, size_t from, size_t *out, size_t cap, size_t *resume) {
    __m128i lo0 = _mm_loadu_si128((const __m128i *)table), hi0 = _mm_loadu_si128((const __m128i *)(table + 16));
    __m128i lo1 = _mm_loadu_si128((const __m128i *)(table + 32)), hi1 = _mm_loadu_si128((const __m128i *)(table + 48));
    __m128i mask = _mm_set1_epi8(15);
    size_t i = from, n = 0;
    while (i + 17 <= len && n + 16 <= cap) {
        if (i + 65 <= len && n + 64 <= cap) {
            unsigned m0 = nonzero_lanes(candidates_ssse3(lo0, hi0, lo1, hi1, mask, h + i));
            unsigned m1 = nonzero_lanes(candidates_ssse3(lo0, hi0, lo1, hi1, mask, h + i + 16));
            unsigned m2 = nonzero_lanes(candidates_ssse3(lo0, hi0, lo1, hi1, mask, h + i + 32));
            unsigned m3 = nonzero_lanes(candidates_ssse3(lo0, hi0, lo1, hi1, mask, h + i + 48));
            if (m0 | m1 | m2 | m3) {
                n = emit_ssse3(m0, i, out, n);
                n = emit_ssse3(m1, i + 16, out, n);
                n = emit_ssse3(m2, i + 32, out, n);
                n = emit_ssse3(m3, i + 48, out, n);
            }
            i += 64;
            continue;
        }
        n = emit_ssse3(nonzero_lanes(candidates_ssse3(lo0, hi0, lo1, hi1, mask, h + i)), i, out, n);
        i += 16;
    }
    if (i + 17 <= len) { *resume = i; return n; }
    return candidates_scalar(table, h, len, i, out, n, cap, resume);
}

#endif

size_t adf_pair_set_candidates(
    const uint8_t *table, const uint8_t *h, size_t len, size_t from, size_t *out, size_t cap, size_t *resume) {
    if (from >= len) { *resume = len; return 0; }
    // A block can hold 16 candidates; with less room than that only the scalar path is guaranteed to make progress.
    if (cap < 16) return candidates_scalar(table, h, len, from, out, 0, cap, resume);
#if defined(__aarch64__)
    return candidates_neon_batch(table, h, len, from, out, cap, resume);
#elif defined(__x86_64__)
    if (adf_kernels_isa() >= ADF_ISA_X86_SSE42)  // SSE4.2 implies SSSE3
        return candidates_ssse3_batch(table, h, len, from, out, cap, resume);
    return candidates_scalar(table, h, len, from, out, 0, cap, resume);
#else
    return candidates_scalar(table, h, len, from, out, 0, cap, resume);
#endif
}

size_t adf_pair_set_find(const uint8_t *table, const uint8_t *h, size_t len, size_t from) {
#if defined(__aarch64__)
    return find_neon(table, h, len, from);
#elif defined(__x86_64__)
    if (adf_kernels_isa() >= ADF_ISA_X86_SSE42)  // SSE4.2 implies SSSE3
        return find_ssse3(table, h, len, from);
    return adf_pair_set_find_scalar(table, h, len, from);
#else
    return adf_pair_set_find_scalar(table, h, len, from);
#endif
}

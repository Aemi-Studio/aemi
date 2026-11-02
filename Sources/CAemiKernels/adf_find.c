//
//  adf_find.c
//  CAemiKernels
//
//  The first occurrence of a byte string in another, for `AemiKernel.ByteSearch`: the vector filter of Muła's "SIMD-friendly
//  substring search" (a start is a candidate when both its first and its last byte match the needle's), each candidate then
//  compared 8 bytes at a time. NEON on arm64, AVX2 or SSE2 on x86-64, a scalar reference everywhere; no libc.
//
//  Abuse resistance: a crafted input can make every start a candidate (`aaaa...` for `aa...ab...a`), and comparing each would
//  take time proportional to `hlen * nlen`. The bytes compared are counted against a budget proportional to the haystack; past it
//  the kernel stops and reports how far every start has been ruled out, and the caller finishes with a linear-time search
//  (Knuth-Morris-Pratt in `ByteSearch`). So no input costs more than linear time.
//
//  Memory safety: a filter load at `i` reads hay[i ..< i + W] and hay[i + nlen - 1 ..< i + nlen - 1 + W] only when
//  i + nlen - 1 + W <= hlen; comparisons read hay[p ..< p + nlen] with p + nlen <= hlen.
//

#include "CAemiKernels.h"

#if defined(__aarch64__)
#include <arm_neon.h>
#endif
#if defined(__x86_64__)
#include <CAemiCPU.h>
#include <immintrin.h>
#endif

/// Whether `a[0 ..< n]` equals `b[0 ..< n]`, adding to `*work` the bytes compared.
static inline int find_equal(const uint8_t *a, const uint8_t *b, size_t n, size_t *work) {
    size_t k = 0;
    for (; k + 8 <= n; k += 8) {
        uint64_t x, y;
        __builtin_memcpy(&x, a + k, 8);
        __builtin_memcpy(&y, b + k, 8);
        if (x != y) {
            *work += k + 8;
            return 0;
        }
    }
    for (; k < n; k++) {
        if (a[k] != b[k]) {
            *work += k + 1;
            return 0;
        }
    }
    *work += n;
    return 1;
}

/// The budget of compared bytes: a constant multiple of the haystack, plus room for a few whole needles.
static inline size_t find_budget(size_t hlen, size_t nlen) { return 8 * hlen + 4 * nlen + 4096; }

/// Starts `from ..< last + 1` one by one. Returns a match, SIZE_MAX for none, or ADF_FIND_GAVE_UP with `*resume`.
static size_t find_tail(const uint8_t *hay, size_t hlen, const uint8_t *needle, size_t nlen, size_t from, size_t *work,
                        size_t budget, size_t *resume) {
    const uint8_t first = needle[0], last = needle[nlen - 1];
    for (size_t p = from; p + nlen <= hlen; p++) {
        if (hay[p] != first || hay[p + nlen - 1] != last) continue;
        if (*work > budget) {
            *resume = p;
            return ADF_FIND_GAVE_UP;
        }
        if (find_equal(hay + p + 1, needle + 1, nlen - 2, work)) return p;
    }
    return SIZE_MAX;
}

size_t adf_find_scalar(const uint8_t *hay, size_t hlen, const uint8_t *needle, size_t nlen) {
    if (nlen == 0) return 0;
    if (nlen > hlen) return SIZE_MAX;
    for (size_t p = 0; p + nlen <= hlen; p++) {
        size_t k = 0;
        while (k < nlen && hay[p + k] == needle[k]) k++;
        if (k == nlen) return p;
    }
    return SIZE_MAX;
}

/// Checks the candidates `bits` (lane `k` at bits `k << shift`, `1 << shift` wide) of the block at `i`, in order.
static inline size_t find_candidates(const uint8_t *hay, const uint8_t *needle, size_t nlen, size_t i, uint64_t bits, unsigned shift,
                                     size_t *work, size_t budget, size_t *resume) {
    const uint64_t unit = (1ull << (1u << shift)) - 1;
    while (bits) {
        const size_t lane = (size_t)__builtin_ctzll(bits) >> shift;
        bits &= ~(unit << (lane << shift));
        const size_t p = i + lane;
        if (*work > budget) {
            *resume = p;
            return ADF_FIND_GAVE_UP;
        }
        if (find_equal(hay + p + 1, needle + 1, nlen - 2, work)) return p;
    }
    return SIZE_MAX;
}

#if defined(__aarch64__)

size_t adf_find(const uint8_t *hay, size_t hlen, const uint8_t *needle, size_t nlen, size_t *resume) {
    *resume = 0;
    if (nlen < 2 || nlen > hlen) return nlen == 0 ? 0 : (nlen > hlen ? SIZE_MAX : adf_find_scalar(hay, hlen, needle, nlen));
    const uint8x16_t first = vdupq_n_u8(needle[0]), last = vdupq_n_u8(needle[nlen - 1]);
    const size_t budget = find_budget(hlen, nlen);
    size_t work = 0, i = 0;
    // hay[i ..< i + 16] and hay[i + nlen - 1 ..< i + nlen + 15]: both inside because i + nlen + 15 <= hlen.
    for (; i + nlen + 15 <= hlen; i += 16) {
        const uint8x16_t m = vandq_u8(vceqq_u8(vld1q_u8(hay + i), first), vceqq_u8(vld1q_u8(hay + i + nlen - 1), last));
        const uint64_t bits = vget_lane_u64(vreinterpret_u64_u8(vshrn_n_u16(vreinterpretq_u16_u8(m), 4)), 0);
        if (bits == 0) continue;
        const size_t found = find_candidates(hay, needle, nlen, i, bits, 2, &work, budget, resume);
        if (found != SIZE_MAX) return found;
    }
    return find_tail(hay, hlen, needle, nlen, i, &work, budget, resume);
}

#elif defined(__x86_64__)

__attribute__((target("avx2"))) static size_t find_avx2(const uint8_t *hay, size_t hlen, const uint8_t *needle, size_t nlen,
                                                       size_t *resume) {
    const __m256i first = _mm256_set1_epi8((char)needle[0]), last = _mm256_set1_epi8((char)needle[nlen - 1]);
    const size_t budget = find_budget(hlen, nlen);
    size_t work = 0, i = 0;
    // hay[i ..< i + 32] and hay[i + nlen - 1 ..< i + nlen + 31], inside because i + nlen + 31 <= hlen.
    for (; i + nlen + 31 <= hlen; i += 32) {
        const __m256i a = _mm256_cmpeq_epi8(_mm256_loadu_si256((const __m256i *)(const void *)(hay + i)), first);
        const __m256i b = _mm256_cmpeq_epi8(_mm256_loadu_si256((const __m256i *)(const void *)(hay + i + nlen - 1)), last);
        const uint32_t bits = (uint32_t)_mm256_movemask_epi8(_mm256_and_si256(a, b));
        if (bits == 0) continue;
        const size_t found = find_candidates(hay, needle, nlen, i, bits, 0, &work, budget, resume);
        if (found != SIZE_MAX) return found;
    }
    return find_tail(hay, hlen, needle, nlen, i, &work, budget, resume);
}

static size_t find_sse2(const uint8_t *hay, size_t hlen, const uint8_t *needle, size_t nlen, size_t *resume) {
    const __m128i first = _mm_set1_epi8((char)needle[0]), last = _mm_set1_epi8((char)needle[nlen - 1]);
    const size_t budget = find_budget(hlen, nlen);
    size_t work = 0, i = 0;
    for (; i + nlen + 15 <= hlen; i += 16) {
        const __m128i a = _mm_cmpeq_epi8(_mm_loadu_si128((const __m128i *)(const void *)(hay + i)), first);
        const __m128i b = _mm_cmpeq_epi8(_mm_loadu_si128((const __m128i *)(const void *)(hay + i + nlen - 1)), last);
        const uint32_t bits = (uint32_t)_mm_movemask_epi8(_mm_and_si128(a, b));
        if (bits == 0) continue;
        const size_t found = find_candidates(hay, needle, nlen, i, bits, 0, &work, budget, resume);
        if (found != SIZE_MAX) return found;
    }
    return find_tail(hay, hlen, needle, nlen, i, &work, budget, resume);
}

size_t adf_find_avx2(const uint8_t *hay, size_t hlen, const uint8_t *needle, size_t nlen, size_t *resume) {
    *resume = 0;
    if (nlen < 2 || nlen > hlen) return nlen == 0 ? 0 : (nlen > hlen ? SIZE_MAX : adf_find_scalar(hay, hlen, needle, nlen));
    return adf_cpu_has(ADF_CPU_AVX2) ? find_avx2(hay, hlen, needle, nlen, resume) : find_sse2(hay, hlen, needle, nlen, resume);
}

size_t adf_find_sse2(const uint8_t *hay, size_t hlen, const uint8_t *needle, size_t nlen, size_t *resume) {
    *resume = 0;
    if (nlen < 2 || nlen > hlen) return nlen == 0 ? 0 : (nlen > hlen ? SIZE_MAX : adf_find_scalar(hay, hlen, needle, nlen));
    return find_sse2(hay, hlen, needle, nlen, resume);
}

size_t adf_find(const uint8_t *hay, size_t hlen, const uint8_t *needle, size_t nlen, size_t *resume) {
    // As for the other kernels (ADR 0025): a process translated by Rosetta 2 takes the 128-bit path.
    if (!adf_cpu_has(ADF_CPU_TRANSLATED)) return adf_find_avx2(hay, hlen, needle, nlen, resume);
    return adf_find_sse2(hay, hlen, needle, nlen, resume);
}

#else

size_t adf_find(const uint8_t *hay, size_t hlen, const uint8_t *needle, size_t nlen, size_t *resume) {
    *resume = 0;
    if (nlen < 2 || nlen > hlen) return nlen == 0 ? 0 : (nlen > hlen ? SIZE_MAX : adf_find_scalar(hay, hlen, needle, nlen));
    size_t work = 0;
    return find_tail(hay, hlen, needle, nlen, 0, &work, find_budget(hlen, nlen), resume);
}

#endif

#if !defined(__x86_64__)
// The x86-64 backends by name, for tests: here they are the dispatched kernel.
size_t adf_find_avx2(const uint8_t *hay, size_t hlen, const uint8_t *needle, size_t nlen, size_t *resume) {
    return adf_find(hay, hlen, needle, nlen, resume);
}
size_t adf_find_sse2(const uint8_t *hay, size_t hlen, const uint8_t *needle, size_t nlen, size_t *resume) {
    return adf_find(hay, hlen, needle, nlen, resume);
}
#endif

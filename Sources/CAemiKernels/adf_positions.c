//
//  adf_positions.c
//  CAemiKernels
//
//  Every position of either of two bytes, written to an array in one pass: the line starts of a text (LF and CR), the field
//  separators of a record, without a call per hit. `base` is added to each position, so a caller scanning a long input in pieces
//  writes absolute offsets. The output is bounded: a vector step runs only while the output has room for every lane of it, and
//  the rest goes byte by byte; when the output is full the scan stops, and `*consumed` says how far every hit was written, so
//  the caller resumes there with fresh room (ADR 0031).
//
//  arm64: two compares per 16 bytes, the lane mask narrowed to four bits a lane (adf_neon_scan.h), each set lane written; a
//  64-byte step skips whole blocks with no hit. x86-64: SSE2 (the baseline) and AVX2, `movemask` giving one bit a lane.
//

#include "CAemiKernels.h"

#if defined(__aarch64__)
#include "adf_neon_scan.h"
#elif defined(__x86_64__)
#include <immintrin.h>
#endif

size_t adf_positions_of_either_scalar(
    const uint8_t *buf, size_t len, uint8_t a, uint8_t b, uint32_t base, uint32_t *out, size_t cap, size_t *consumed) {
    size_t n = 0, i = 0;
    for (; i < len; ++i) {
        if (buf[i] == a || buf[i] == b) {
            if (n == cap) break;
            out[n++] = base + (uint32_t)i;
        }
    }
    *consumed = i;
    return n;
}

/// Bytes `buf[i ..< len]` byte by byte while the output has room: the tail of every backend.
static inline size_t positions_tail(
    const uint8_t *buf, size_t i, size_t len, uint8_t a, uint8_t b, uint32_t base, uint32_t *out, size_t n, size_t cap,
    size_t *consumed) {
    for (; i < len; ++i) {
        if (buf[i] == a || buf[i] == b) {
            if (n == cap) break;
            out[n++] = base + (uint32_t)i;
        }
    }
    *consumed = i;
    return n;
}

#if defined(__aarch64__)
static size_t positions_neon(
    const uint8_t *buf, size_t len, uint8_t a, uint8_t b, uint32_t base, uint32_t *out, size_t cap, size_t *consumed) {
    const uint8x16_t va = vdupq_n_u8(a), vb = vdupq_n_u8(b);
    size_t n = 0, i = 0;
    // A 64-byte block is taken only when the output has room for 64 more positions.
    for (; i + 64 <= len && cap - n >= 64; i += 64) {  // buf[i ..< i + 64] is inside the input
        uint8x16_t m[4];
        for (int k = 0; k < 4; k++) {
            const uint8x16_t v = vld1q_u8(buf + i + 16 * (size_t)k);
            m[k] = vorrq_u8(vceqq_u8(v, va), vceqq_u8(v, vb));
        }
        if (vmaxvq_u8(vorrq_u8(vorrq_u8(m[0], m[1]), vorrq_u8(m[2], m[3]))) == 0) continue;
        for (int k = 0; k < 4; k++) {
            uint64_t bits = adf_neon_lane_bits(m[k]);
            while (bits != 0) {
                const unsigned shift = (unsigned)__builtin_ctzll(bits) & ~3u;  // the lowest set lane's nibble
                out[n++] = base + (uint32_t)(i + 16 * (size_t)k + (shift >> 2));
                bits &= ~((uint64_t)0xF << shift);
            }
        }
    }
    for (; i + 16 <= len && cap - n >= 16; i += 16) {  // buf[i ..< i + 16] is inside the input
        const uint8x16_t v = vld1q_u8(buf + i);
        uint64_t bits = adf_neon_lane_bits(vorrq_u8(vceqq_u8(v, va), vceqq_u8(v, vb)));
        while (bits != 0) {
            const unsigned shift = (unsigned)__builtin_ctzll(bits) & ~3u;
            out[n++] = base + (uint32_t)(i + (shift >> 2));
            bits &= ~((uint64_t)0xF << shift);
        }
    }
    return positions_tail(buf, i, len, a, b, base, out, n, cap, consumed);
}
#endif

#if defined(__x86_64__)
static size_t positions_sse2(
    const uint8_t *buf, size_t len, uint8_t a, uint8_t b, uint32_t base, uint32_t *out, size_t cap, size_t *consumed) {
    const __m128i va = _mm_set1_epi8((char)a), vb = _mm_set1_epi8((char)b);
    size_t n = 0, i = 0;
    for (; i + 16 <= len && cap - n >= 16; i += 16) {  // buf[i ..< i + 16] is inside the input
        const __m128i v = _mm_loadu_si128((const __m128i *)(buf + i));
        unsigned mask = (unsigned)_mm_movemask_epi8(_mm_or_si128(_mm_cmpeq_epi8(v, va), _mm_cmpeq_epi8(v, vb))) & 0xFFFFu;
        while (mask != 0) {
            out[n++] = base + (uint32_t)(i + (size_t)__builtin_ctz(mask));
            mask &= mask - 1;
        }
    }
    return positions_tail(buf, i, len, a, b, base, out, n, cap, consumed);
}

__attribute__((target("avx2")))
static size_t positions_avx2(
    const uint8_t *buf, size_t len, uint8_t a, uint8_t b, uint32_t base, uint32_t *out, size_t cap, size_t *consumed) {
    const __m256i va = _mm256_set1_epi8((char)a), vb = _mm256_set1_epi8((char)b);
    size_t n = 0, i = 0;
    for (; i + 32 <= len && cap - n >= 32; i += 32) {  // buf[i ..< i + 32] is inside the input
        const __m256i v = _mm256_loadu_si256((const __m256i *)(buf + i));
        unsigned mask = (unsigned)_mm256_movemask_epi8(_mm256_or_si256(_mm256_cmpeq_epi8(v, va), _mm256_cmpeq_epi8(v, vb)));
        while (mask != 0) {
            out[n++] = base + (uint32_t)(i + (size_t)__builtin_ctz(mask));
            mask &= mask - 1;
        }
    }
    return positions_tail(buf, i, len, a, b, base, out, n, cap, consumed);
}
#endif

size_t adf_positions_of_either(
    const uint8_t *buf, size_t len, uint8_t a, uint8_t b, uint32_t base, uint32_t *out, size_t cap, size_t *consumed) {
#if defined(__aarch64__)
    return positions_neon(buf, len, a, b, base, out, cap, consumed);
#elif defined(__x86_64__)
    if (adf_kernels_isa() >= ADF_ISA_X86_AVX2) {
        return positions_avx2(buf, len, a, b, base, out, cap, consumed);
    }
    return positions_sse2(buf, len, a, b, base, out, cap, consumed);
#else
    return adf_positions_of_either_scalar(buf, len, a, b, base, out, cap, consumed);
#endif
}

//
//  adf_percent.c
//  CAemiKernels
//
//  Percent-coding (RFC 3986) for `AemiKernel.PercentCoding`: a count of the bytes a set marks, an encoder that copies 16-byte
//  blocks holding no such byte and escapes the others as `%XY`, and a decoder that copies blocks holding no `%` (nor `+` for
//  forms) and decodes the rest byte by byte. The set is the two nibble tables of `adf_index_of_set` (a byte `b` is in it when
//  `lo[b & 15] & hi[b >> 4] != 0`). NEON on arm64, SSSE3 (encode, count) and SSE2 (decode) on x86-64, scalar references.
//
//  Memory safety: the encoder writes only below `out_cap` and returns SIZE_MAX rather than pass it; the decoder writes at most
//  `len` bytes, never ahead of what it has read (a 16-byte store at `w` happens only when `i + 16 <= len`, and `w <= i`).
//

#include "CAemiKernels.h"

#include <stdint.h>

#if defined(__aarch64__)
#include <arm_neon.h>
#endif
#if defined(__x86_64__)
#include <CAemiCPU.h>
#include <immintrin.h>
#endif

static const uint8_t pct_digits[16] = {'0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'A', 'B', 'C', 'D', 'E', 'F'};

static inline int pct_in_set(uint8_t b, const uint8_t lo[16], const uint8_t hi[16]) { return (lo[b & 15] & hi[b >> 4]) != 0; }

static inline uint8_t pct_hex(uint8_t c) {
    if (c >= '0' && c <= '9') return (uint8_t)(c - '0');
    const uint8_t l = (uint8_t)(c | 0x20);
    if (l >= 'a' && l <= 'f') return (uint8_t)(l - 'a' + 10);
    return 0xFF;
}

size_t adf_count_in_set_scalar(const uint8_t *buf, size_t len, const uint8_t lo[16], const uint8_t hi[16]) {
    size_t count = 0;
    for (size_t i = 0; i < len; i++) count += (size_t)pct_in_set(buf[i], lo, hi);
    return count;
}

/// Escapes `in[i ..< end]` byte by byte from output position `w`; returns the new `w`, or SIZE_MAX if `out_cap` would be passed.
static inline size_t pct_encode_bytes(const uint8_t *in, size_t i, size_t end, const uint8_t lo[16], const uint8_t hi[16],
                                      uint8_t *out, size_t w, size_t out_cap) {
    for (; i < end; i++) {
        const uint8_t b = in[i];
        if (pct_in_set(b, lo, hi)) {
            if (out_cap - w < 3) return SIZE_MAX;
            out[w] = '%';
            out[w + 1] = pct_digits[b >> 4];
            out[w + 2] = pct_digits[b & 15];
            w += 3;
        } else {
            if (out_cap - w < 1) return SIZE_MAX;
            out[w++] = b;
        }
    }
    return w;
}

size_t adf_percent_encode_scalar(const uint8_t *in, size_t len, const uint8_t lo[16], const uint8_t hi[16], uint8_t *out,
                                 size_t out_cap) {
    return pct_encode_bytes(in, 0, len, lo, hi, out, 0, out_cap);
}

/// Decodes `in[i]` (a `%` or `+`, or any byte) onto `out[*w]`; returns the next input index, or SIZE_MAX for a malformed escape.
static inline size_t pct_decode_one(const uint8_t *in, size_t len, size_t i, uint8_t *out, size_t *w, int plus) {
    const uint8_t b = in[i];
    if (b == '%') {
        if (len - i < 3) return SIZE_MAX;
        const uint8_t high = pct_hex(in[i + 1]), low = pct_hex(in[i + 2]);
        if (high > 15 || low > 15) return SIZE_MAX;
        out[(*w)++] = (uint8_t)(high << 4 | low);
        return i + 3;
    }
    out[(*w)++] = (plus && b == '+') ? ' ' : b;
    return i + 1;
}

size_t adf_percent_decode_scalar(const uint8_t *in, size_t len, uint8_t *out, int plus, size_t *bad) {
    size_t i = 0, w = 0;
    while (i < len) {
        const size_t next = pct_decode_one(in, len, i, out, &w, plus);
        if (next == SIZE_MAX) {
            *bad = i;
            return SIZE_MAX;
        }
        i = next;
    }
    return w;
}

/// Copies `in[from ..< to]` (fewer than 16 bytes) to `out[w ...]`: one 16-byte copy when both sides have room, else byte by byte.
/// Returns the new `w`, or SIZE_MAX if `out_cap` would be passed.
static inline size_t pct_copy_run(const uint8_t *in, size_t len, size_t from, size_t to, uint8_t *out, size_t w, size_t out_cap) {
    const size_t n = to - from;
    if (out_cap - w < n) return SIZE_MAX;
    if (len - from >= 16 && out_cap - w >= 16) {
        __builtin_memcpy(out + w, in + from, 16);  // a fixed 16-byte copy: one load and one store, no call
    } else {
        for (size_t k = 0; k < n; k++) out[w + k] = in[from + k];
    }
    return w + n;
}

/// One 16-byte block at `i` whose escapes are the set lanes of `bits` (lane `k` is bits `k << shift` and up, `1 << shift` wide):
/// copies the runs between escapes and writes each escape. Returns the new `w`, or SIZE_MAX if `out_cap` would be passed.
static inline size_t pct_encode_block(const uint8_t *in, size_t len, size_t i, uint64_t bits, unsigned shift, uint8_t *out, size_t w,
                                      size_t out_cap) {
    size_t j = 0;
    const uint64_t unit = (1ull << (1u << shift)) - 1;
    while (bits) {
        const size_t lane = (size_t)__builtin_ctzll(bits) >> shift;
        bits &= ~(unit << (lane << shift));
        w = pct_copy_run(in, len, i + j, i + lane, out, w, out_cap);
        if (w == SIZE_MAX || out_cap - w < 3) return SIZE_MAX;
        const uint8_t b = in[i + lane];
        out[w] = '%';
        out[w + 1] = pct_digits[b >> 4];
        out[w + 2] = pct_digits[b & 15];
        w += 3;
        j = lane + 1;
    }
    return j < 16 ? pct_copy_run(in, len, i + j, i + 16, out, w, out_cap) : w;
}

/// One 16-byte block at `*i` whose `%` (and `+` for forms) are the set lanes of `bits`: copies the runs and decodes each escape.
/// An escape may end past the block; `*i` is left after the last byte consumed. Returns the new `w`, or SIZE_MAX with `*bad`.
static inline size_t pct_decode_block(const uint8_t *in, size_t len, size_t *i, uint64_t bits, unsigned shift, uint8_t *out, size_t w,
                                      int plus, size_t *bad) {
    const size_t base = *i;
    size_t j = 0;
    const uint64_t unit = (1ull << (1u << shift)) - 1;
    while (bits) {
        const size_t lane = (size_t)__builtin_ctzll(bits) >> shift;
        bits &= ~(unit << (lane << shift));
        if (lane < j) continue;  // inside an escape already decoded (its digits are never % or +, but stay safe)
        w = pct_copy_run(in, len, base + j, base + lane, out, w, SIZE_MAX);
        const size_t next = pct_decode_one(in, len, base + lane, out, &w, plus);
        if (next == SIZE_MAX) {
            *bad = base + lane;
            return SIZE_MAX;
        }
        j = next - base;
    }
    if (j < 16) {
        w = pct_copy_run(in, len, base + j, base + 16, out, w, SIZE_MAX);
        j = 16;
    }
    *i = base + j;
    return w;
}

#if defined(__aarch64__)

#define PCT_INLINE __attribute__((always_inline)) static inline

PCT_INLINE uint8x16_t pct_classify(uint8x16_t v, uint8x16_t lo, uint8x16_t hi) {
    return vtstq_u8(vqtbl1q_u8(lo, vandq_u8(v, vdupq_n_u8(15))), vqtbl1q_u8(hi, vshrq_n_u8(v, 4)));
}

size_t adf_count_in_set(const uint8_t *buf, size_t len, const uint8_t lo[16], const uint8_t hi[16]) {
    const uint8x16_t vlo = vld1q_u8(lo), vhi = vld1q_u8(hi);
    size_t count = 0, i = 0;
    // Blocks of up to 255 vectors, so no u8 lane can wrap; each reads buf[i ..< i + 16].
    while (len - i >= 16) {
        uint8x16_t acc = vdupq_n_u8(0);
        for (size_t k = 0; k < 255 && len - i >= 16; k++, i += 16) acc = vsubq_u8(acc, pct_classify(vld1q_u8(buf + i), vlo, vhi));
        count += vaddlvq_u8(acc);
    }
    return count + adf_count_in_set_scalar(buf + i, len - i, lo, hi);
}

size_t adf_percent_encode(const uint8_t *in, size_t len, const uint8_t lo[16], const uint8_t hi[16], uint8_t *out, size_t out_cap) {
    const uint8x16_t vlo = vld1q_u8(lo), vhi = vld1q_u8(hi);
    size_t i = 0, w = 0;
    // A block of 16 bytes none of which is in the set is copied whole: reads in[i ..< i + 16], writes out[w ..< w + 16].
    while (len - i >= 16) {
        const uint8x16_t v = vld1q_u8(in + i);
        if (vmaxvq_u8(pct_classify(v, vlo, vhi)) == 0 && out_cap - w >= 16) {
            vst1q_u8(out + w, v);
            i += 16;
            w += 16;
            continue;
        }
        const uint8x16_t mask = pct_classify(v, vlo, vhi);
        const uint64_t bits = vget_lane_u64(vreinterpret_u64_u8(vshrn_n_u16(vreinterpretq_u16_u8(mask), 4)), 0);
        w = pct_encode_block(in, len, i, bits, 2, out, w, out_cap);
        if (w == SIZE_MAX) return SIZE_MAX;
        i += 16;
    }
    return pct_encode_bytes(in, i, len, lo, hi, out, w, out_cap);
}

size_t adf_percent_decode(const uint8_t *in, size_t len, uint8_t *out, int plus, size_t *bad) {
    const uint8x16_t percent = vdupq_n_u8('%'), plusSign = vdupq_n_u8(plus ? '+' : '%');
    size_t i = 0, w = 0;
    while (i < len) {
        if (len - i >= 16) {
            // A block with no `%` (nor `+` for forms) is copied whole: reads in[i ..< i + 16], writes out[w ..< w + 16], w <= i.
            const uint8x16_t v = vld1q_u8(in + i);
            const uint8x16_t mask = vorrq_u8(vceqq_u8(v, percent), vceqq_u8(v, plusSign));
            if (vmaxvq_u8(mask) == 0) {
                vst1q_u8(out + w, v);
                i += 16;
                w += 16;
                continue;
            }
            // Otherwise the runs between escapes are copied and each escape decoded (one may run into the next block).
            const uint64_t bits = vget_lane_u64(vreinterpret_u64_u8(vshrn_n_u16(vreinterpretq_u16_u8(mask), 4)), 0);
            w = pct_decode_block(in, len, &i, bits, 2, out, w, plus, bad);
            if (w == SIZE_MAX) return SIZE_MAX;
            continue;
        }
        const size_t next = pct_decode_one(in, len, i, out, &w, plus);
        if (next == SIZE_MAX) {
            *bad = i;
            return SIZE_MAX;
        }
        i = next;
    }
    return w;
}

#elif defined(__x86_64__)

#define PCT_SSSE3 __attribute__((target("ssse3")))

PCT_SSSE3 static inline int pct_mask_ssse3(__m128i v, __m128i lo, __m128i hi) {
    const __m128i nibble = _mm_set1_epi8(15);
    const __m128i both = _mm_and_si128(_mm_shuffle_epi8(lo, _mm_and_si128(v, nibble)),
                                       _mm_shuffle_epi8(hi, _mm_and_si128(_mm_srli_epi16(v, 4), nibble)));
    return ~_mm_movemask_epi8(_mm_cmpeq_epi8(both, _mm_setzero_si128())) & 0xFFFF;
}

PCT_SSSE3 static size_t pct_count_ssse3(const uint8_t *buf, size_t len, const uint8_t lo[16], const uint8_t hi[16]) {
    const __m128i vlo = _mm_loadu_si128((const __m128i *)(const void *)lo), vhi = _mm_loadu_si128((const __m128i *)(const void *)hi);
    size_t count = 0, i = 0;
    for (; len - i >= 16; i += 16) count += (size_t)__builtin_popcount((unsigned)pct_mask_ssse3(_mm_loadu_si128((const __m128i *)(const void *)(buf + i)), vlo, vhi));
    return count + adf_count_in_set_scalar(buf + i, len - i, lo, hi);
}

PCT_SSSE3 static size_t pct_encode_ssse3(const uint8_t *in, size_t len, const uint8_t lo[16], const uint8_t hi[16], uint8_t *out,
                                         size_t out_cap) {
    const __m128i vlo = _mm_loadu_si128((const __m128i *)(const void *)lo), vhi = _mm_loadu_si128((const __m128i *)(const void *)hi);
    size_t i = 0, w = 0;
    while (len - i >= 16) {
        const __m128i v = _mm_loadu_si128((const __m128i *)(const void *)(in + i));
        const int mask = pct_mask_ssse3(v, vlo, vhi);
        if (mask == 0 && out_cap - w >= 16) {
            _mm_storeu_si128((__m128i *)(void *)(out + w), v);
            i += 16;
            w += 16;
            continue;
        }
        w = pct_encode_block(in, len, i, (uint64_t)(unsigned)mask, 0, out, w, out_cap);
        if (w == SIZE_MAX) return SIZE_MAX;
        i += 16;
    }
    return pct_encode_bytes(in, i, len, lo, hi, out, w, out_cap);
}

size_t adf_count_in_set(const uint8_t *buf, size_t len, const uint8_t lo[16], const uint8_t hi[16]) {
    return adf_cpu_has(ADF_CPU_SSSE3) ? pct_count_ssse3(buf, len, lo, hi) : adf_count_in_set_scalar(buf, len, lo, hi);
}

size_t adf_percent_encode(const uint8_t *in, size_t len, const uint8_t lo[16], const uint8_t hi[16], uint8_t *out, size_t out_cap) {
    return adf_cpu_has(ADF_CPU_SSSE3) ? pct_encode_ssse3(in, len, lo, hi, out, out_cap)
                                      : adf_percent_encode_scalar(in, len, lo, hi, out, out_cap);
}

size_t adf_percent_decode(const uint8_t *in, size_t len, uint8_t *out, int plus, size_t *bad) {
    // SSE2 is baseline on x86-64.
    const __m128i percent = _mm_set1_epi8('%'), plusSign = _mm_set1_epi8(plus ? '+' : '%');
    size_t i = 0, w = 0;
    while (i < len) {
        if (len - i >= 16) {
            const __m128i v = _mm_loadu_si128((const __m128i *)(const void *)(in + i));
            const int mask = _mm_movemask_epi8(_mm_or_si128(_mm_cmpeq_epi8(v, percent), _mm_cmpeq_epi8(v, plusSign)));
            if (mask == 0) {
                _mm_storeu_si128((__m128i *)(void *)(out + w), v);
                i += 16;
                w += 16;
                continue;
            }
            w = pct_decode_block(in, len, &i, (uint64_t)(unsigned)mask, 0, out, w, plus, bad);
            if (w == SIZE_MAX) return SIZE_MAX;
            continue;
        }
        const size_t next = pct_decode_one(in, len, i, out, &w, plus);
        if (next == SIZE_MAX) {
            *bad = i;
            return SIZE_MAX;
        }
        i = next;
    }
    return w;
}

#else

size_t adf_count_in_set(const uint8_t *buf, size_t len, const uint8_t lo[16], const uint8_t hi[16]) {
    return adf_count_in_set_scalar(buf, len, lo, hi);
}
size_t adf_percent_encode(const uint8_t *in, size_t len, const uint8_t lo[16], const uint8_t hi[16], uint8_t *out, size_t out_cap) {
    return adf_percent_encode_scalar(in, len, lo, hi, out, out_cap);
}
size_t adf_percent_decode(const uint8_t *in, size_t len, uint8_t *out, int plus, size_t *bad) {
    return adf_percent_decode_scalar(in, len, out, plus, bad);
}

#endif

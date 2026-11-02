//
//  adf_hex.c
//  CAemiKernels
//
//  Hexadecimal: bytes to digits and digits back, for `AemiKernel.Hex`. NEON on arm64 (a `tbl` lookup of the 16 digits and
//  `st2`/`ld2` to interleave the two digits of each byte), SSSE3 and AVX2 on x86-64 (`pshufb` and `maddubs`), a scalar
//  reference everywhere. Encode always writes every byte; decode stops at the first pair holding a byte that is not a digit, and
//  every backend returns exactly the scalar reference's answer (a vector block holding a bad byte is handed to it), so the
//  caller's error reporting never depends on the ISA. Tails are one more vector step overlapping bytes already done.
//
//  Memory safety: each load and store is stated against `in[0 ..< len]` and `out[0 ..< 2 * len]` (encode) or
//  `out[0 ..< len / 2]` (decode) at the loop that issues it.
//

#include "CAemiKernels.h"

#if defined(__aarch64__)
#include <arm_neon.h>
#endif
#if defined(__x86_64__)
#include <CAemiCPU.h>
#include <immintrin.h>
#endif

static const uint8_t hex_lower[16] = {'0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f'};
static const uint8_t hex_upper[16] = {'0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'A', 'B', 'C', 'D', 'E', 'F'};

void adf_hex_encode_scalar(const uint8_t *in, size_t len, uint8_t *out, int upper) {
    const uint8_t *digits = upper ? hex_upper : hex_lower;
    for (size_t i = 0; i < len; i++) {
        out[2 * i] = digits[in[i] >> 4];
        out[2 * i + 1] = digits[in[i] & 15];
    }
}

/// The value of a hex digit (either case), or 0xFF.
static inline uint8_t hex_value(uint8_t c) {
    if (c >= '0' && c <= '9') return (uint8_t)(c - '0');
    const uint8_t l = (uint8_t)(c | 0x20);
    if (l >= 'a' && l <= 'f') return (uint8_t)(l - 'a' + 10);
    return 0xFF;
}

size_t adf_hex_decode_scalar(const uint8_t *in, size_t len, uint8_t *out) {
    size_t i = 0;
    for (; i + 2 <= len; i += 2) {
        const uint8_t hi = hex_value(in[i]), lo = hex_value(in[i + 1]);
        if (hi > 15 || lo > 15) break;
        out[i / 2] = (uint8_t)(hi << 4 | lo);
    }
    return i;
}

#if defined(__aarch64__)

#define HEX_INLINE __attribute__((always_inline)) static inline

void adf_hex_encode(const uint8_t *in, size_t len, uint8_t *out, int upper) {
    if (len < 16) {
        adf_hex_encode_scalar(in, len, out, upper);
        return;
    }
    const uint8x16_t digits = vld1q_u8(upper ? hex_upper : hex_lower);
    const uint8x16_t low = vdupq_n_u8(15);
    size_t i = 0;
    // Reads in[i ..< i + 32]; writes out[2 * i ..< 2 * i + 64].
    for (; i + 32 <= len; i += 32) {
        const uint8x16_t a = vld1q_u8(in + i), b = vld1q_u8(in + i + 16);
        uint8x16x2_t x, y;
        x.val[0] = vqtbl1q_u8(digits, vshrq_n_u8(a, 4));
        x.val[1] = vqtbl1q_u8(digits, vandq_u8(a, low));
        y.val[0] = vqtbl1q_u8(digits, vshrq_n_u8(b, 4));
        y.val[1] = vqtbl1q_u8(digits, vandq_u8(b, low));
        vst2q_u8(out + 2 * i, x);
        vst2q_u8(out + 2 * i + 32, y);
    }
    // 16 at a time, the last one placed to end on the last byte (rewriting digits already written with the same ones):
    // reads in[p ..< p + 16], writes out[2 * p ..< 2 * p + 32], p + 16 <= len.
    while (i < len) {
        const size_t p = len - i >= 16 ? i : len - 16;
        const uint8x16_t a = vld1q_u8(in + p);
        uint8x16x2_t x;
        x.val[0] = vqtbl1q_u8(digits, vshrq_n_u8(a, 4));
        x.val[1] = vqtbl1q_u8(digits, vandq_u8(a, low));
        vst2q_u8(out + 2 * p, x);
        i = p + 16;
    }
}

/// The values of 16 digits, and in `*bad` a nonzero lane where a byte is not a digit.
HEX_INLINE uint8x16_t hex_values16(uint8x16_t c, uint8x16_t *bad) {
    const uint8x16_t d = vsubq_u8(c, vdupq_n_u8('0'));
    const uint8x16_t l = vsubq_u8(vorrq_u8(c, vdupq_n_u8(0x20)), vdupq_n_u8('a'));
    const uint8x16_t isDigit = vcltq_u8(d, vdupq_n_u8(10));
    const uint8x16_t isLetter = vcltq_u8(l, vdupq_n_u8(6));
    *bad = vmvnq_u8(vorrq_u8(isDigit, isLetter));
    return vbslq_u8(isDigit, d, vaddq_u8(l, vdupq_n_u8(10)));
}

size_t adf_hex_decode(const uint8_t *in, size_t len, uint8_t *out) {
    const size_t whole = len / 2 * 2;
    size_t i = 0;
    if (whole < 32) goto rest;
    // Reads in[i ..< i + 32] as 16 pairs; writes out[i / 2 ..< i / 2 + 16]. A block with a bad byte is not stored.
    for (; i + 32 <= whole; i += 32) {
        const uint8x16x2_t x = vld2q_u8(in + i);
        uint8x16_t badHi, badLo;
        const uint8x16_t hi = hex_values16(x.val[0], &badHi), lo = hex_values16(x.val[1], &badLo);
        if (vmaxvq_u8(vorrq_u8(badHi, badLo)) != 0) goto rest;
        vst1q_u8(out + i / 2, vsliq_n_u8(lo, hi, 4));
    }
    if (i < whole) {
        // The last 2 to 30 digits: the 32 ending on the last pair; pairs already decoded (and valid) decode the same again.
        const size_t p = whole - 32;
        const uint8x16x2_t x = vld2q_u8(in + p);
        uint8x16_t badHi, badLo;
        const uint8x16_t hi = hex_values16(x.val[0], &badHi), lo = hex_values16(x.val[1], &badLo);
        if (vmaxvq_u8(vorrq_u8(badHi, badLo)) != 0) goto rest;
        vst1q_u8(out + p / 2, vsliq_n_u8(lo, hi, 4));
        return whole;
    }
    return whole;
rest:
    return i + adf_hex_decode_scalar(in + i, whole - i, out + i / 2);
}

#elif defined(__x86_64__)

#define HEX_SSSE3 __attribute__((target("ssse3")))
#define HEX_AVX2 __attribute__((target("avx2")))
#define HEX_INLINE __attribute__((always_inline)) static inline

/// Writes the 32 digits of the 16 bytes of `v` at `out`.
HEX_SSSE3 HEX_INLINE void hex_encode16_x86(__m128i v, __m128i digits, uint8_t *out) {
    const __m128i low = _mm_set1_epi8(15);
    const __m128i hi = _mm_shuffle_epi8(digits, _mm_and_si128(_mm_srli_epi16(v, 4), low));
    const __m128i lo = _mm_shuffle_epi8(digits, _mm_and_si128(v, low));
    _mm_storeu_si128((__m128i *)(void *)out, _mm_unpacklo_epi8(hi, lo));
    _mm_storeu_si128((__m128i *)(void *)(out + 16), _mm_unpackhi_epi8(hi, lo));
}

HEX_SSSE3 HEX_INLINE void hex_encode_ssse3_from(const uint8_t *in, size_t len, uint8_t *out, int upper, size_t i) {
    const __m128i digits = _mm_loadu_si128((const __m128i *)(const void *)(upper ? hex_upper : hex_lower));
    // 16 at a time, the last placed to end on the last byte: reads in[p ..< p + 16], writes out[2 * p ..< 2 * p + 32].
    while (i < len) {
        const size_t p = len - i >= 16 ? i : len - 16;
        hex_encode16_x86(_mm_loadu_si128((const __m128i *)(const void *)(in + p)), digits, out + 2 * p);
        i = p + 16;
    }
}

HEX_SSSE3 static void hex_encode_ssse3(const uint8_t *in, size_t len, uint8_t *out, int upper) {
    hex_encode_ssse3_from(in, len, out, upper, 0);
}

HEX_AVX2 static void hex_encode_avx2(const uint8_t *in, size_t len, uint8_t *out, int upper) {
    const __m256i digits = _mm256_broadcastsi128_si256(_mm_loadu_si128((const __m128i *)(const void *)(upper ? hex_upper : hex_lower)));
    const __m256i low = _mm256_set1_epi8(15);
    size_t i = 0;
    // Reads in[i ..< i + 32]; writes out[2 * i ..< 2 * i + 64]. The unpacks work within 128-bit lanes, so the two halves are put
    // back in order with a lane permute.
    for (; i + 32 <= len; i += 32) {
        const __m256i v = _mm256_loadu_si256((const __m256i *)(const void *)(in + i));
        const __m256i hi = _mm256_shuffle_epi8(digits, _mm256_and_si256(_mm256_srli_epi16(v, 4), low));
        const __m256i lo = _mm256_shuffle_epi8(digits, _mm256_and_si256(v, low));
        const __m256i a = _mm256_unpacklo_epi8(hi, lo), b = _mm256_unpackhi_epi8(hi, lo);
        _mm256_storeu_si256((__m256i *)(void *)(out + 2 * i), _mm256_permute2x128_si256(a, b, 0x20));
        _mm256_storeu_si256((__m256i *)(void *)(out + 2 * i + 32), _mm256_permute2x128_si256(a, b, 0x31));
    }
    hex_encode_ssse3_from(in, len, out, upper, i);  // AVX2 implies SSSE3
}

void adf_hex_encode_ssse3(const uint8_t *in, size_t len, uint8_t *out, int upper) {
    if (len < 16 || !adf_cpu_has(ADF_CPU_SSSE3)) {
        adf_hex_encode_scalar(in, len, out, upper);
        return;
    }
    hex_encode_ssse3(in, len, out, upper);
}

void adf_hex_encode_avx2(const uint8_t *in, size_t len, uint8_t *out, int upper) {
    if (len < 16 || !adf_cpu_has(ADF_CPU_AVX2)) {
        adf_hex_encode_ssse3(in, len, out, upper);
        return;
    }
    hex_encode_avx2(in, len, out, upper);
}

void adf_hex_encode(const uint8_t *in, size_t len, uint8_t *out, int upper) {
    // As for Base64 (ADR 0025): a process translated by Rosetta 2 takes SSSE3.
    if (adf_cpu_has(ADF_CPU_TRANSLATED)) {
        adf_hex_encode_ssse3(in, len, out, upper);
    } else {
        adf_hex_encode_avx2(in, len, out, upper);
    }
}

/// The values of the digits in `c`, and in `*valid` 0xFF lanes where a byte is a digit.
#define HEX_VALUES(VEC, SET1, SUB, OR, AND, ANDNOT, MIN, CMPEQ, ADD)                                    \
    const VEC d = SUB(c, SET1('0'));                                                                    \
    const VEC l = SUB(OR(c, SET1(0x20)), SET1('a'));                                                    \
    const VEC isDigit = CMPEQ(MIN(d, SET1(9)), d);                                                      \
    const VEC isLetter = CMPEQ(MIN(l, SET1(5)), l);                                                     \
    *valid = OR(isDigit, isLetter);                                                                     \
    return OR(AND(isDigit, d), ANDNOT(isDigit, ADD(l, SET1(10))));

HEX_SSSE3 HEX_INLINE __m128i hex_values128(__m128i c, __m128i *valid) {
    HEX_VALUES(__m128i, _mm_set1_epi8, _mm_sub_epi8, _mm_or_si128, _mm_and_si128, _mm_andnot_si128, _mm_min_epu8, _mm_cmpeq_epi8,
               _mm_add_epi8)
}

HEX_AVX2 HEX_INLINE __m256i hex_values256(__m256i c, __m256i *valid) {
    HEX_VALUES(__m256i, _mm256_set1_epi8, _mm256_sub_epi8, _mm256_or_si256, _mm256_and_si256, _mm256_andnot_si256, _mm256_min_epu8,
               _mm256_cmpeq_epi8, _mm256_add_epi8)
}

/// 16 digits from `i` on, the last step placed to end on the last pair, and the scalar reference from a block with a bad byte.
HEX_SSSE3 HEX_INLINE size_t hex_decode_ssse3_from(const uint8_t *in, size_t len, uint8_t *out, size_t i) {
    const size_t whole = len / 2 * 2;
    const __m128i weights = _mm_set1_epi16(0x0110);  // high digit * 16 + low digit, per pair
    __m128i valid;
    if (whole < 16) goto rest;
    // Reads in[p ..< p + 16]; writes the 8 bytes out[p / 2 ..< p / 2 + 8].
    while (i < whole) {
        const size_t p = whole - i >= 16 ? i : whole - 16;
        const __m128i v = hex_values128(_mm_loadu_si128((const __m128i *)(const void *)(in + p)), &valid);
        if (_mm_movemask_epi8(valid) != 0xFFFF) goto rest;
        const __m128i pairs = _mm_maddubs_epi16(v, weights);
        _mm_storel_epi64((__m128i *)(void *)(out + p / 2), _mm_packus_epi16(pairs, pairs));
        i = p + 16;
    }
    return whole;
rest:
    return i + adf_hex_decode_scalar(in + i, whole - i, out + i / 2);
}

HEX_SSSE3 static size_t hex_decode_ssse3(const uint8_t *in, size_t len, uint8_t *out) { return hex_decode_ssse3_from(in, len, out, 0); }

HEX_AVX2 static size_t hex_decode_avx2(const uint8_t *in, size_t len, uint8_t *out) {
    const size_t whole = len / 2 * 2;
    const __m256i weights = _mm256_set1_epi16(0x0110);
    size_t i = 0;
    // Reads in[i ..< i + 32]; writes out[i / 2 ..< i / 2 + 16]. `packus` works within lanes, so the 8-byte halves are gathered.
    for (; i + 32 <= whole; i += 32) {
        __m256i valid;
        const __m256i v = hex_values256(_mm256_loadu_si256((const __m256i *)(const void *)(in + i)), &valid);
        if (_mm256_movemask_epi8(valid) != -1) break;  // the SSSE3 steps, then the reference, take it from here
        const __m256i pairs = _mm256_maddubs_epi16(v, weights);
        const __m256i packed = _mm256_permute4x64_epi64(_mm256_packus_epi16(pairs, pairs), 0x08);
        _mm_storeu_si128((__m128i *)(void *)(out + i / 2), _mm256_castsi256_si128(packed));
    }
    return hex_decode_ssse3_from(in, len, out, i);
}

size_t adf_hex_decode_ssse3(const uint8_t *in, size_t len, uint8_t *out) {
    if (!adf_cpu_has(ADF_CPU_SSSE3)) return adf_hex_decode_scalar(in, len, out);
    return hex_decode_ssse3(in, len, out);
}

size_t adf_hex_decode_avx2(const uint8_t *in, size_t len, uint8_t *out) {
    if (!adf_cpu_has(ADF_CPU_AVX2)) return adf_hex_decode_ssse3(in, len, out);
    return hex_decode_avx2(in, len, out);
}

size_t adf_hex_decode(const uint8_t *in, size_t len, uint8_t *out) {
    if (adf_cpu_has(ADF_CPU_TRANSLATED)) return adf_hex_decode_ssse3(in, len, out);
    return adf_hex_decode_avx2(in, len, out);
}

#else

void adf_hex_encode(const uint8_t *in, size_t len, uint8_t *out, int upper) { adf_hex_encode_scalar(in, len, out, upper); }
size_t adf_hex_decode(const uint8_t *in, size_t len, uint8_t *out) { return adf_hex_decode_scalar(in, len, out); }

#endif

#if !defined(__x86_64__)
// The x86-64 backends by name, for tests: here they are the scalar reference.
void adf_hex_encode_ssse3(const uint8_t *in, size_t len, uint8_t *out, int upper) { adf_hex_encode_scalar(in, len, out, upper); }
void adf_hex_encode_avx2(const uint8_t *in, size_t len, uint8_t *out, int upper) { adf_hex_encode_scalar(in, len, out, upper); }
size_t adf_hex_decode_ssse3(const uint8_t *in, size_t len, uint8_t *out) { return adf_hex_decode_scalar(in, len, out); }
size_t adf_hex_decode_avx2(const uint8_t *in, size_t len, uint8_t *out) { return adf_hex_decode_scalar(in, len, out); }
#endif

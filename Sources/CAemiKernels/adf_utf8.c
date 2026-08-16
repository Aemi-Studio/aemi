//
//  adf_utf8.c
//  CAemiKernels
//
//  Whole-buffer UTF-8 validation (RFC 3629) that validates MULTI-BYTE sequences in-vector, 16 bytes
//  per step, via the simdjson/Lemire "lookup4" algorithm — three nibble-`pshufb`/`tbl` classification
//  tables (special cases: overlong / surrogate / too-large / too-short / too-long / two-continuations)
//  plus a "must-be-a-continuation" length check, with cross-16-byte-block carry. This replaces the
//  adaptive validator's scalar fallback on non-ASCII-dense text (measured 21× slower than ASCII).
//
//  The public entry returns the FIRST-INVALID byte offset (or `len` if well-formed). The SIMD kernels
//  decide validity for the whole buffer as a bool; the exact offset is pinpointed by a scalar rescan
//  only on the (rare) invalid path — so the scalar `adf_first_invalid_utf8_scalar` is both the
//  differential-test oracle AND the offset finder, which makes an over-strict SIMD table a mere perf
//  regression (self-corrected by the rescan) while an under-strict one is caught by the oracle.
//

#include "CAemiKernels.h"

#if defined(__x86_64__)
#include <immintrin.h>
#elif defined(__aarch64__)
#include <arm_neon.h>
#endif

// MARK: - Scalar reference (the oracle + the offset finder)

size_t adf_first_invalid_utf8_scalar(const uint8_t *p, size_t n) {
    size_t i = 0;
    while (i < n) {
        uint8_t b = p[i];
        if (b < 0x80) {
            i += 1;
            continue;
        }
        size_t length;
        uint32_t lower_bound, scalar;
        if ((b & 0xE0) == 0xC0) {
            length = 2;
            lower_bound = 0x80;
            scalar = b & 0x1F;
        } else if ((b & 0xF0) == 0xE0) {
            length = 3;
            lower_bound = 0x800;
            scalar = b & 0x0F;
        } else if ((b & 0xF8) == 0xF0) {
            length = 4;
            lower_bound = 0x10000;
            scalar = b & 0x07;
        } else {
            return i;  // continuation byte or invalid lead
        }
        if (i + length > n) {
            return i;  // truncated
        }
        for (size_t k = 1; k < length; ++k) {
            uint8_t c = p[i + k];
            if ((c & 0xC0) != 0x80) {
                return i;
            }
            scalar = (scalar << 6) | (c & 0x3F);
        }
        uint32_t upper_bound = length == 2 ? 0x7FF : (length == 3 ? 0xFFFF : 0x10FFFF);
        if (scalar < lower_bound || scalar > upper_bound) {
            return i;
        }
        if (scalar >= 0xD800 && scalar <= 0xDFFF) {
            return i;  // surrogate
        }
        i += length;
    }
    return n;
}

// MARK: - simdjson/Lemire classification tables (shared by NEON + SSE)
//
// Error-condition bit flags. `special = t1h[prev>>4] & t1l[prev&0xF] & t2h[cur>>4]` isolates the error
// class for the (prev, cur) byte pair; the length check (`must23 ^ special`) enforces that continuation
// bytes appear exactly where a 2/3/4-byte lead requires them. See the header for the derivation notes.

#define ADF_TOO_SHORT (1 << 0)       // 11______ 0_______
#define ADF_TOO_LONG (1 << 1)        // 0_______ 10______
#define ADF_OVERLONG_3 (1 << 2)      // 11100000 100_____
#define ADF_TOO_LARGE (1 << 3)       // 11110100 1001____
#define ADF_SURROGATE (1 << 4)       // 11101101 101_____
#define ADF_OVERLONG_2 (1 << 5)      // 1100000_ 10______
#define ADF_TOO_LARGE_1000 (1 << 6)  // 11110101 1000____
#define ADF_OVERLONG_4 (1 << 6)      // 11110000 1000____  (shares bit 6)
#define ADF_TWO_CONTS (1 << 7)       // 10______ 10______
#define ADF_CARRY (ADF_TOO_SHORT | ADF_TOO_LONG | ADF_TWO_CONTS)

// Indexed by the high nibble of the PREVIOUS byte.
static const uint8_t adf_utf8_t1h[16] = {
    ADF_TOO_LONG, ADF_TOO_LONG, ADF_TOO_LONG, ADF_TOO_LONG,
    ADF_TOO_LONG, ADF_TOO_LONG, ADF_TOO_LONG, ADF_TOO_LONG,
    ADF_TWO_CONTS, ADF_TWO_CONTS, ADF_TWO_CONTS, ADF_TWO_CONTS,
    ADF_TOO_SHORT | ADF_OVERLONG_2,                                   // C
    ADF_TOO_SHORT,                                                    // D
    ADF_TOO_SHORT | ADF_OVERLONG_3 | ADF_SURROGATE,                   // E
    ADF_TOO_SHORT | ADF_TOO_LARGE | ADF_TOO_LARGE_1000 | ADF_OVERLONG_4  // F
};

// Indexed by the low nibble of the PREVIOUS byte.
static const uint8_t adf_utf8_t1l[16] = {
    ADF_CARRY | ADF_OVERLONG_2 | ADF_OVERLONG_3 | ADF_OVERLONG_4,  // 0
    ADF_CARRY | ADF_OVERLONG_2,                                    // 1
    ADF_CARRY, ADF_CARRY,                                          // 2,3
    ADF_CARRY | ADF_TOO_LARGE,                                     // 4
    ADF_CARRY | ADF_TOO_LARGE | ADF_TOO_LARGE_1000,               // 5
    ADF_CARRY | ADF_TOO_LARGE | ADF_TOO_LARGE_1000,               // 6
    ADF_CARRY | ADF_TOO_LARGE | ADF_TOO_LARGE_1000,               // 7
    ADF_CARRY | ADF_TOO_LARGE | ADF_TOO_LARGE_1000,               // 8
    ADF_CARRY | ADF_TOO_LARGE | ADF_TOO_LARGE_1000,               // 9
    ADF_CARRY | ADF_TOO_LARGE | ADF_TOO_LARGE_1000,               // A
    ADF_CARRY | ADF_TOO_LARGE | ADF_TOO_LARGE_1000,               // B
    ADF_CARRY | ADF_TOO_LARGE | ADF_TOO_LARGE_1000,               // C
    ADF_CARRY | ADF_TOO_LARGE | ADF_TOO_LARGE_1000 | ADF_SURROGATE,  // D
    ADF_CARRY | ADF_TOO_LARGE | ADF_TOO_LARGE_1000,               // E
    ADF_CARRY | ADF_TOO_LARGE | ADF_TOO_LARGE_1000                // F
};

// Indexed by the high nibble of the CURRENT byte.
static const uint8_t adf_utf8_t2h[16] = {
    ADF_TOO_SHORT, ADF_TOO_SHORT, ADF_TOO_SHORT, ADF_TOO_SHORT,
    ADF_TOO_SHORT, ADF_TOO_SHORT, ADF_TOO_SHORT, ADF_TOO_SHORT,
    ADF_TOO_LONG | ADF_OVERLONG_2 | ADF_TWO_CONTS | ADF_OVERLONG_3 | ADF_OVERLONG_4,  // 8
    ADF_TOO_LONG | ADF_OVERLONG_2 | ADF_TWO_CONTS | ADF_OVERLONG_3 | ADF_TOO_LARGE,   // 9
    ADF_TOO_LONG | ADF_OVERLONG_2 | ADF_TWO_CONTS | ADF_SURROGATE | ADF_TOO_LARGE,    // A
    ADF_TOO_LONG | ADF_OVERLONG_2 | ADF_TWO_CONTS | ADF_SURROGATE | ADF_TOO_LARGE,    // B
    ADF_TOO_SHORT, ADF_TOO_SHORT, ADF_TOO_SHORT, ADF_TOO_SHORT
};

// The per-lane maximum for the last 3 positions: a lead too big for the bytes remaining in the buffer
// is an incomplete (truncated) sequence. Used only when `len` is a positive multiple of 16.
static const uint8_t adf_utf8_max_incomplete[16] = {
    0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
    0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xEF, 0xDF, 0xBF
};

// MARK: - arm64 NEON

#if defined(__aarch64__)
static inline uint8x16_t adf_utf8_block_neon(
    uint8x16_t prev, uint8x16_t input, uint8x16_t t1h, uint8x16_t t1l, uint8x16_t t2h) {
    uint8x16_t lowNibble = vdupq_n_u8(0x0F);
    uint8x16_t prev1 = vextq_u8(prev, input, 16 - 1);
    uint8x16_t sc1 = vqtbl1q_u8(t1h, vshrq_n_u8(prev1, 4));
    uint8x16_t sc2 = vqtbl1q_u8(t1l, vandq_u8(prev1, lowNibble));
    uint8x16_t sc3 = vqtbl1q_u8(t2h, vshrq_n_u8(input, 4));
    uint8x16_t special = vandq_u8(vandq_u8(sc1, sc2), sc3);
    uint8x16_t prev2 = vextq_u8(prev, input, 16 - 2);
    uint8x16_t prev3 = vextq_u8(prev, input, 16 - 3);
    uint8x16_t is3 = vqsubq_u8(prev2, vdupq_n_u8(0xDF));  // > 0 iff prev2 >= 0xE0
    uint8x16_t is4 = vqsubq_u8(prev3, vdupq_n_u8(0xEF));  // > 0 iff prev3 >= 0xF0
    uint8x16_t must = vcgtq_u8(vorrq_u8(is3, is4), vdupq_n_u8(0));  // 0xFF where a continuation is required
    uint8x16_t must80 = vandq_u8(must, vdupq_n_u8(0x80));
    return veorq_u8(must80, special);
}

static int adf_utf8_valid_neon(const uint8_t *data, size_t len) {
    const uint8x16_t t1h = vld1q_u8(adf_utf8_t1h);
    const uint8x16_t t1l = vld1q_u8(adf_utf8_t1l);
    const uint8x16_t t2h = vld1q_u8(adf_utf8_t2h);
    const uint8x16_t maxInc = vld1q_u8(adf_utf8_max_incomplete);
    const uint8x16_t highBit = vdupq_n_u8(0x80);
    const uint8x16_t zero = vdupq_n_u8(0);
    uint8x16_t prev = zero;
    uint8x16_t prevIncomplete = zero;  // is_incomplete(prev block): a trailing lead needing more bytes
    uint8x16_t error = zero;
    size_t i = 0;
    for (; i + 16 <= len; i += 16) {
        uint8x16_t input = vld1q_u8(data + i);
        if (vmaxvq_u8(vandq_u8(input, highBit)) == 0) {
            // All-ASCII block: valid in itself. The only possible error is that the PREVIOUS block ended
            // with a lead this block fails to continue — captured by `prevIncomplete`.
            error = vorrq_u8(error, prevIncomplete);
            prevIncomplete = zero;
        } else {
            error = vorrq_u8(error, adf_utf8_block_neon(prev, input, t1h, t1l, t2h));
            prevIncomplete = vqsubq_u8(input, maxInc);
        }
        prev = input;
    }
    if (i < len) {
        uint8_t tmp[16] = { 0 };
        for (size_t k = 0; i + k < len; ++k) {
            tmp[k] = data[i + k];
        }
        // Full-check the tail (may hold multibyte or a trailing lead); zero padding makes a trailing
        // lead meet a non-continuation => TOO_SHORT, and the cross-boundary check uses `prev`.
        uint8x16_t input = vld1q_u8(tmp);
        error = vorrq_u8(error, adf_utf8_block_neon(prev, input, t1h, t1l, t2h));
    } else {
        error = vorrq_u8(error, prevIncomplete);  // last full block's trailing incompleteness
    }
    return vmaxvq_u8(error) == 0;
}
#endif  // __aarch64__

// MARK: - x86-64 SSE (SSSE3 pshufb/alignr; gated at the SSE4.2 tier)

#if defined(__x86_64__)
__attribute__((target("sse4.2")))
static inline __m128i adf_utf8_block_sse(
    __m128i prev, __m128i input, __m128i t1h, __m128i t1l, __m128i t2h) {
    const __m128i lowNibble = _mm_set1_epi8(0x0F);
    __m128i prev1 = _mm_alignr_epi8(input, prev, 16 - 1);
    __m128i sc1 = _mm_shuffle_epi8(t1h, _mm_and_si128(_mm_srli_epi16(prev1, 4), lowNibble));
    __m128i sc2 = _mm_shuffle_epi8(t1l, _mm_and_si128(prev1, lowNibble));
    __m128i sc3 = _mm_shuffle_epi8(t2h, _mm_and_si128(_mm_srli_epi16(input, 4), lowNibble));
    __m128i special = _mm_and_si128(_mm_and_si128(sc1, sc2), sc3);
    __m128i prev2 = _mm_alignr_epi8(input, prev, 16 - 2);
    __m128i prev3 = _mm_alignr_epi8(input, prev, 16 - 3);
    __m128i is3 = _mm_subs_epu8(prev2, _mm_set1_epi8((char)0xDF));
    __m128i is4 = _mm_subs_epu8(prev3, _mm_set1_epi8((char)0xEF));
    __m128i orv = _mm_or_si128(is3, is4);
    // 0x80 where a continuation is required (orv != 0): andnot(cmpeq(orv,0), 0x80).
    __m128i must80 =
        _mm_andnot_si128(_mm_cmpeq_epi8(orv, _mm_setzero_si128()), _mm_set1_epi8((char)0x80));
    return _mm_xor_si128(must80, special);
}

__attribute__((target("sse4.2")))
static int adf_utf8_valid_sse(const uint8_t *data, size_t len) {
    const __m128i t1h = _mm_loadu_si128((const __m128i *)adf_utf8_t1h);
    const __m128i t1l = _mm_loadu_si128((const __m128i *)adf_utf8_t1l);
    const __m128i t2h = _mm_loadu_si128((const __m128i *)adf_utf8_t2h);
    const __m128i maxInc = _mm_loadu_si128((const __m128i *)adf_utf8_max_incomplete);
    const __m128i zero = _mm_setzero_si128();
    __m128i prev = zero;
    __m128i prevIncomplete = zero;
    __m128i error = zero;
    size_t i = 0;
    for (; i + 16 <= len; i += 16) {
        __m128i input = _mm_loadu_si128((const __m128i *)(data + i));
        if (_mm_movemask_epi8(input) == 0) {  // all high bits clear => all-ASCII block
            error = _mm_or_si128(error, prevIncomplete);
            prevIncomplete = zero;
        } else {
            error = _mm_or_si128(error, adf_utf8_block_sse(prev, input, t1h, t1l, t2h));
            prevIncomplete = _mm_subs_epu8(input, maxInc);
        }
        prev = input;
    }
    if (i < len) {
        uint8_t tmp[16] = { 0 };
        for (size_t k = 0; i + k < len; ++k) {
            tmp[k] = data[i + k];
        }
        __m128i input = _mm_loadu_si128((const __m128i *)tmp);
        error = _mm_or_si128(error, adf_utf8_block_sse(prev, input, t1h, t1l, t2h));
    } else {
        error = _mm_or_si128(error, prevIncomplete);
    }
    return _mm_movemask_epi8(_mm_cmpeq_epi8(error, zero)) == 0xFFFF;
}
#endif  // __x86_64__

// MARK: - Dispatcher (offset via scalar rescan on the invalid path)

size_t adf_first_invalid_utf8(const uint8_t *buf, size_t len) {
    if (len == 0) {
        return 0;
    }
    int valid = 0;
#if defined(__x86_64__)
    if (adf_kernels_isa() >= ADF_ISA_X86_SSE42) {  // SSE4.2 tier implies SSSE3 (pshufb/alignr)
        valid = adf_utf8_valid_sse(buf, len);
    } else {
        return adf_first_invalid_utf8_scalar(buf, len);  // SSE2-only baseline has no pshufb
    }
#elif defined(__aarch64__)
    valid = adf_utf8_valid_neon(buf, len);
#else
    return adf_first_invalid_utf8_scalar(buf, len);
#endif
    return valid ? len : adf_first_invalid_utf8_scalar(buf, len);
}

//
//  adf_scan.c
//  CAemiKernels
//
//  Byte scanners. `string_stop` finds the first byte a JSON/wire string reader must stop on (control,
//  non-ASCII, quote, or escape) — the hot inner loop of a tape/string parser — vectorized so long runs
//  of plain content advance 16/32 bytes at a time. On x86 the first-hit lane comes from movemask+ctz;
//  on arm64 the five scanners share adf_neon_scan.h (ADR-0014), which locates the hit from the compare
//  mask and ends with an overlapping load. `index_of_byte` routes to libc `memchr` (already
//  vectorized). All backends agree with the scalar reference.
//

#include "CAemiKernels.h"
#include "adf_neon_scan.h"

#include <string.h>

#if defined(__x86_64__)
#include <immintrin.h>
#elif defined(__aarch64__)
#include <arm_neon.h>
#endif

// MARK: - Scalar reference (the differential-test oracle)

size_t adf_index_of_string_stop_scalar(const uint8_t *buf, size_t len, uint8_t quote, uint8_t escape) {
    for (size_t i = 0; i < len; ++i) {
        uint8_t b = buf[i];
        if (b < 0x20 || b >= 0x80 || b == quote || b == escape) {
            return i;
        }
    }
    return len;
}

// MARK: - x86-64 implementations

#if defined(__x86_64__)
static size_t stop_sse2_impl(const uint8_t *buf, size_t len, uint8_t quote, uint8_t escape) {
    const __m128i vCtrl = _mm_set1_epi8(0x1F);  // b <= 0x1F  ⇔  max_epu8(b, 0x1F) == 0x1F
    const __m128i vQuote = _mm_set1_epi8((char)quote);
    const __m128i vEsc = _mm_set1_epi8((char)escape);
    const __m128i vZero = _mm_setzero_si128();
    size_t i = 0;
    for (; i + 16 <= len; i += 16) {
        __m128i v = _mm_loadu_si128((const __m128i *)(buf + i));
        __m128i isCtrl = _mm_cmpeq_epi8(_mm_max_epu8(v, vCtrl), vCtrl);
        __m128i isHigh = _mm_cmpgt_epi8(vZero, v);  // signed(v) < 0  ⇔  b >= 0x80
        __m128i isQ = _mm_cmpeq_epi8(v, vQuote);
        __m128i isE = _mm_cmpeq_epi8(v, vEsc);
        __m128i stop = _mm_or_si128(_mm_or_si128(isCtrl, isHigh), _mm_or_si128(isQ, isE));
        int mask = _mm_movemask_epi8(stop);
        if (mask != 0) {
            return i + (size_t)__builtin_ctz((unsigned)mask);
        }
    }
    if (i < len) {
        size_t r = adf_index_of_string_stop_scalar(buf + i, len - i, quote, escape);
        return (r == len - i) ? len : i + r;
    }
    return len;
}

__attribute__((target("avx2")))
static size_t stop_avx2_impl(const uint8_t *buf, size_t len, uint8_t quote, uint8_t escape) {
    const __m256i vCtrl = _mm256_set1_epi8(0x1F);
    const __m256i vQuote = _mm256_set1_epi8((char)quote);
    const __m256i vEsc = _mm256_set1_epi8((char)escape);
    const __m256i vZero = _mm256_setzero_si256();
    size_t i = 0;
    for (; i + 32 <= len; i += 32) {
        __m256i v = _mm256_loadu_si256((const __m256i *)(buf + i));
        __m256i isCtrl = _mm256_cmpeq_epi8(_mm256_max_epu8(v, vCtrl), vCtrl);
        __m256i isHigh = _mm256_cmpgt_epi8(vZero, v);
        __m256i isQ = _mm256_cmpeq_epi8(v, vQuote);
        __m256i isE = _mm256_cmpeq_epi8(v, vEsc);
        __m256i stop = _mm256_or_si256(_mm256_or_si256(isCtrl, isHigh), _mm256_or_si256(isQ, isE));
        unsigned mask = (unsigned)_mm256_movemask_epi8(stop);
        if (mask != 0) {
            return i + (size_t)__builtin_ctz(mask);
        }
    }
    // Scalar tail (integer code — no AVX↔SSE transition to guard against).
    if (i < len) {
        size_t r = adf_index_of_string_stop_scalar(buf + i, len - i, quote, escape);
        return (r == len - i) ? len : i + r;
    }
    return len;
}
#endif  // __x86_64__

// MARK: - arm64 implementation

#if defined(__aarch64__)
typedef struct {
    uint8x16_t quote, escape;
    uint8_t quoteByte, escapeByte;
} stop_ctx;

__attribute__((always_inline)) static inline uint8x16_t stop_classify(uint8x16_t v, const void *ctx) {
    const stop_ctx *c = (const stop_ctx *)ctx;
    const uint8x16_t control = vcleq_u8(v, vdupq_n_u8(0x1F));  // b <= 0x1F
    const uint8x16_t high = vcgeq_u8(v, vdupq_n_u8(0x80));     // b >= 0x80
    return vorrq_u8(vorrq_u8(control, high), vorrq_u8(vceqq_u8(v, c->quote), vceqq_u8(v, c->escape)));
}

__attribute__((always_inline)) static inline size_t stop_scalar(const uint8_t *buf, size_t len, const void *ctx) {
    const stop_ctx *c = (const stop_ctx *)ctx;
    return adf_index_of_string_stop_scalar(buf, len, c->quoteByte, c->escapeByte);
}

static size_t stop_neon_impl(const uint8_t *buf, size_t len, uint8_t quote, uint8_t escape) {
    const stop_ctx ctx = {vdupq_n_u8(quote), vdupq_n_u8(escape), quote, escape};
    return adf_neon_scan(buf, len, stop_classify, stop_scalar, &ctx);
}
#endif  // __aarch64__

// MARK: - Named backends (self-guarding) + best-available dispatcher

size_t adf_index_of_string_stop_sse2(const uint8_t *buf, size_t len, uint8_t quote, uint8_t escape) {
#if defined(__x86_64__)
    return stop_sse2_impl(buf, len, quote, escape);
#else
    return adf_index_of_string_stop_scalar(buf, len, quote, escape);
#endif
}

size_t adf_index_of_string_stop_avx2(const uint8_t *buf, size_t len, uint8_t quote, uint8_t escape) {
#if defined(__x86_64__)
    if (adf_kernels_isa() >= ADF_ISA_X86_AVX2) {
        return stop_avx2_impl(buf, len, quote, escape);
    }
    return stop_sse2_impl(buf, len, quote, escape);
#else
    return adf_index_of_string_stop_scalar(buf, len, quote, escape);
#endif
}

size_t adf_index_of_string_stop_neon(const uint8_t *buf, size_t len, uint8_t quote, uint8_t escape) {
#if defined(__aarch64__)
    return stop_neon_impl(buf, len, quote, escape);
#else
    return adf_index_of_string_stop_scalar(buf, len, quote, escape);
#endif
}

size_t adf_index_of_string_stop(const uint8_t *buf, size_t len, uint8_t quote, uint8_t escape) {
#if defined(__aarch64__)
    // NEON is mandatory on arm64 and every tier above it runs this kernel (adf_cpu.c), so there is
    // nothing to look up: the lookup was a pthread_once call on each scan.
    return stop_neon_impl(buf, len, quote, escape);
#else
    switch (adf_kernels_isa()) {
#if defined(__x86_64__)
        case ADF_ISA_X86_AVX512:
        case ADF_ISA_X86_AVX2:
            return stop_avx2_impl(buf, len, quote, escape);
        case ADF_ISA_X86_SSE42:
        case ADF_ISA_X86_SSE2:
            return stop_sse2_impl(buf, len, quote, escape);
#endif
        default:
            return adf_index_of_string_stop_scalar(buf, len, quote, escape);
    }
#endif
}

// MARK: - First byte in a small literal set (up to 5)

size_t adf_index_of_any5_scalar(
    const uint8_t *buf, size_t len, uint8_t n0, uint8_t n1, uint8_t n2, uint8_t n3, uint8_t n4) {
    for (size_t i = 0; i < len; ++i) {
        uint8_t b = buf[i];
        if (b == n0 || b == n1 || b == n2 || b == n3 || b == n4) {
            return i;
        }
    }
    return len;
}

#if defined(__x86_64__)
static size_t any5_sse2_impl(
    const uint8_t *buf, size_t len, uint8_t n0, uint8_t n1, uint8_t n2, uint8_t n3, uint8_t n4) {
    const __m128i v0 = _mm_set1_epi8((char)n0), v1 = _mm_set1_epi8((char)n1);
    const __m128i v2 = _mm_set1_epi8((char)n2), v3 = _mm_set1_epi8((char)n3);
    const __m128i v4 = _mm_set1_epi8((char)n4);
    size_t i = 0;
    for (; i + 16 <= len; i += 16) {
        __m128i v = _mm_loadu_si128((const __m128i *)(buf + i));
        __m128i m = _mm_or_si128(
            _mm_or_si128(_mm_cmpeq_epi8(v, v0), _mm_cmpeq_epi8(v, v1)),
            _mm_or_si128(_mm_or_si128(_mm_cmpeq_epi8(v, v2), _mm_cmpeq_epi8(v, v3)),
                         _mm_cmpeq_epi8(v, v4)));
        int mask = _mm_movemask_epi8(m);
        if (mask != 0) {
            return i + (size_t)__builtin_ctz((unsigned)mask);
        }
    }
    if (i < len) {
        size_t r = adf_index_of_any5_scalar(buf + i, len - i, n0, n1, n2, n3, n4);
        return (r == len - i) ? len : i + r;
    }
    return len;
}

__attribute__((target("avx2")))
static size_t any5_avx2_impl(
    const uint8_t *buf, size_t len, uint8_t n0, uint8_t n1, uint8_t n2, uint8_t n3, uint8_t n4) {
    const __m256i v0 = _mm256_set1_epi8((char)n0), v1 = _mm256_set1_epi8((char)n1);
    const __m256i v2 = _mm256_set1_epi8((char)n2), v3 = _mm256_set1_epi8((char)n3);
    const __m256i v4 = _mm256_set1_epi8((char)n4);
    size_t i = 0;
    for (; i + 32 <= len; i += 32) {
        __m256i v = _mm256_loadu_si256((const __m256i *)(buf + i));
        __m256i m = _mm256_or_si256(
            _mm256_or_si256(_mm256_cmpeq_epi8(v, v0), _mm256_cmpeq_epi8(v, v1)),
            _mm256_or_si256(_mm256_or_si256(_mm256_cmpeq_epi8(v, v2), _mm256_cmpeq_epi8(v, v3)),
                            _mm256_cmpeq_epi8(v, v4)));
        unsigned mask = (unsigned)_mm256_movemask_epi8(m);
        if (mask != 0) {
            return i + (size_t)__builtin_ctz(mask);
        }
    }
    if (i < len) {
        size_t r = adf_index_of_any5_scalar(buf + i, len - i, n0, n1, n2, n3, n4);
        return (r == len - i) ? len : i + r;
    }
    return len;
}
#endif  // __x86_64__

#if defined(__aarch64__)
typedef struct {
    uint8x16_t needle[5];
    uint8_t byte[5];
} any5_ctx;

__attribute__((always_inline)) static inline uint8x16_t any5_classify(uint8x16_t v, const void *ctx) {
    const any5_ctx *c = (const any5_ctx *)ctx;
    return vorrq_u8(
        vorrq_u8(vceqq_u8(v, c->needle[0]), vceqq_u8(v, c->needle[1])),
        vorrq_u8(vorrq_u8(vceqq_u8(v, c->needle[2]), vceqq_u8(v, c->needle[3])), vceqq_u8(v, c->needle[4])));
}

__attribute__((always_inline)) static inline size_t any5_scalar(const uint8_t *buf, size_t len, const void *ctx) {
    const any5_ctx *c = (const any5_ctx *)ctx;
    return adf_index_of_any5_scalar(buf, len, c->byte[0], c->byte[1], c->byte[2], c->byte[3], c->byte[4]);
}

static size_t any5_neon_impl(
    const uint8_t *buf, size_t len, uint8_t n0, uint8_t n1, uint8_t n2, uint8_t n3, uint8_t n4) {
    const any5_ctx ctx = {
        {vdupq_n_u8(n0), vdupq_n_u8(n1), vdupq_n_u8(n2), vdupq_n_u8(n3), vdupq_n_u8(n4)}, {n0, n1, n2, n3, n4}};
    return adf_neon_scan(buf, len, any5_classify, any5_scalar, &ctx);
}
#endif  // __aarch64__

size_t adf_index_of_any5(
    const uint8_t *buf, size_t len, uint8_t n0, uint8_t n1, uint8_t n2, uint8_t n3, uint8_t n4) {
#if defined(__aarch64__)
    // NEON is mandatory on arm64 and every tier above it runs this kernel (adf_cpu.c), so there is
    // nothing to look up: the lookup was a pthread_once call on each scan.
    return any5_neon_impl(buf, len, n0, n1, n2, n3, n4);
#else
    switch (adf_kernels_isa()) {
#if defined(__x86_64__)
        case ADF_ISA_X86_AVX512:
        case ADF_ISA_X86_AVX2:
            return any5_avx2_impl(buf, len, n0, n1, n2, n3, n4);
        case ADF_ISA_X86_SSE42:
        case ADF_ISA_X86_SSE2:
            return any5_sse2_impl(buf, len, n0, n1, n2, n3, n4);
#endif
        default:
            return adf_index_of_any5_scalar(buf, len, n0, n1, n2, n3, n4);
    }
#endif
}

// MARK: - First non-ASCII byte

size_t adf_index_of_nonascii_scalar(const uint8_t *buf, size_t len) {
    for (size_t i = 0; i < len; ++i) {
        if (buf[i] >= 0x80) {
            return i;
        }
    }
    return len;
}

#if defined(__x86_64__)
static size_t nonascii_sse2_impl(const uint8_t *buf, size_t len) {
    const __m128i vZero = _mm_setzero_si128();
    size_t i = 0;
    for (; i + 16 <= len; i += 16) {
        __m128i v = _mm_loadu_si128((const __m128i *)(buf + i));
        int mask = _mm_movemask_epi8(_mm_cmpgt_epi8(vZero, v));  // high bit set ⇔ signed < 0
        if (mask != 0) {
            return i + (size_t)__builtin_ctz((unsigned)mask);
        }
    }
    if (i < len) {
        size_t r = adf_index_of_nonascii_scalar(buf + i, len - i);
        return (r == len - i) ? len : i + r;
    }
    return len;
}

__attribute__((target("avx2")))
static size_t nonascii_avx2_impl(const uint8_t *buf, size_t len) {
    const __m256i vZero = _mm256_setzero_si256();
    size_t i = 0;
    for (; i + 32 <= len; i += 32) {
        __m256i v = _mm256_loadu_si256((const __m256i *)(buf + i));
        unsigned mask = (unsigned)_mm256_movemask_epi8(_mm256_cmpgt_epi8(vZero, v));
        if (mask != 0) {
            return i + (size_t)__builtin_ctz(mask);
        }
    }
    if (i < len) {
        size_t r = adf_index_of_nonascii_scalar(buf + i, len - i);
        return (r == len - i) ? len : i + r;
    }
    return len;
}
#endif  // __x86_64__

#if defined(__aarch64__)
__attribute__((always_inline)) static inline uint8x16_t nonascii_classify(uint8x16_t v, const void *ctx) {
    (void)ctx;
    return vcgeq_u8(v, vdupq_n_u8(0x80));
}

__attribute__((always_inline)) static inline size_t nonascii_scalar(const uint8_t *buf, size_t len, const void *ctx) {
    (void)ctx;
    return adf_index_of_nonascii_scalar(buf, len);
}

static size_t nonascii_neon_impl(const uint8_t *buf, size_t len) {
    return adf_neon_scan(buf, len, nonascii_classify, nonascii_scalar, NULL);
}
#endif  // __aarch64__

size_t adf_index_of_nonascii_sse2(const uint8_t *buf, size_t len) {
#if defined(__x86_64__)
    return nonascii_sse2_impl(buf, len);
#else
    return adf_index_of_nonascii_scalar(buf, len);
#endif
}

size_t adf_index_of_nonascii_avx2(const uint8_t *buf, size_t len) {
#if defined(__x86_64__)
    if (adf_kernels_isa() >= ADF_ISA_X86_AVX2) {
        return nonascii_avx2_impl(buf, len);
    }
    return nonascii_sse2_impl(buf, len);
#else
    return adf_index_of_nonascii_scalar(buf, len);
#endif
}

size_t adf_index_of_nonascii_neon(const uint8_t *buf, size_t len) {
#if defined(__aarch64__)
    return nonascii_neon_impl(buf, len);
#else
    return adf_index_of_nonascii_scalar(buf, len);
#endif
}

size_t adf_index_of_nonascii(const uint8_t *buf, size_t len) {
#if defined(__aarch64__)
    // NEON is mandatory on arm64 and every tier above it runs this kernel (adf_cpu.c), so there is
    // nothing to look up: the lookup was a pthread_once call on each scan.
    return nonascii_neon_impl(buf, len);
#else
    switch (adf_kernels_isa()) {
#if defined(__x86_64__)
        case ADF_ISA_X86_AVX512:
        case ADF_ISA_X86_AVX2:
            return nonascii_avx2_impl(buf, len);
        case ADF_ISA_X86_SSE42:
        case ADF_ISA_X86_SSE2:
            return nonascii_sse2_impl(buf, len);
#endif
        default:
            return adf_index_of_nonascii_scalar(buf, len);
    }
#endif
}

// MARK: - Printable-text validation (control/DEL illegal, obs-text allowed)

size_t adf_first_disallowed_text_scalar(
    const uint8_t *buf, size_t len, uint8_t min_allowed, int allow_tab) {
    for (size_t i = 0; i < len; ++i) {
        uint8_t b = buf[i];
        if (b >= 0x80) {
            continue;  // obs-text always legal
        }
        if (b == 0x7F) {
            return i;  // DEL
        }
        if (b < min_allowed && !(allow_tab && b == 0x09)) {
            return i;
        }
    }
    return len;
}

#if defined(__x86_64__)
// The x86 kernels test `b >= min` (`max(b, min) == b`) and flag the lanes where it fails. Testing
// `b <= min - 1` instead breaks at both ends of the `uint8_t` range: `min_allowed == 0` wraps `min - 1`
// to 0xFF (every byte "low"), and `min_allowed > 0x80` flags the obs-text bytes in `[0x80, min)`. Every
// byte >= 0x80 is legal and every ASCII byte is below any threshold past 0x80, so the threshold is
// clamped to 0x80, which keeps `b >= min` true for all obs-text.
static uint8_t disallowed_simd_threshold(uint8_t min_allowed) {
    return min_allowed > 0x80 ? 0x80 : min_allowed;
}

static size_t disallowed_sse2_impl(
    const uint8_t *buf, size_t len, uint8_t min_allowed, int allow_tab) {
    const __m128i vMin = _mm_set1_epi8((char)disallowed_simd_threshold(min_allowed));
    const __m128i vDEL = _mm_set1_epi8(0x7F);
    const __m128i vTab = _mm_set1_epi8(0x09);
    const __m128i vOnes = _mm_set1_epi8((char)0xFF);
    size_t i = 0;
    for (; i + 16 <= len; i += 16) {
        __m128i v = _mm_loadu_si128((const __m128i *)(buf + i));
        __m128i notLow = _mm_cmpeq_epi8(_mm_max_epu8(v, vMin), v);  // unsigned b >= min
        if (allow_tab) {
            notLow = _mm_or_si128(notLow, _mm_cmpeq_epi8(v, vTab));
        }
        __m128i illegal = _mm_or_si128(_mm_xor_si128(notLow, vOnes), _mm_cmpeq_epi8(v, vDEL));
        int mask = _mm_movemask_epi8(illegal);
        if (mask != 0) {
            return i + (size_t)__builtin_ctz((unsigned)mask);
        }
    }
    if (i < len) {
        size_t r = adf_first_disallowed_text_scalar(buf + i, len - i, min_allowed, allow_tab);
        return (r == len - i) ? len : i + r;
    }
    return len;
}

__attribute__((target("avx2")))
static size_t disallowed_avx2_impl(
    const uint8_t *buf, size_t len, uint8_t min_allowed, int allow_tab) {
    const __m256i vMin = _mm256_set1_epi8((char)disallowed_simd_threshold(min_allowed));
    const __m256i vDEL = _mm256_set1_epi8(0x7F);
    const __m256i vTab = _mm256_set1_epi8(0x09);
    const __m256i vOnes = _mm256_set1_epi8((char)0xFF);
    size_t i = 0;
    for (; i + 32 <= len; i += 32) {
        __m256i v = _mm256_loadu_si256((const __m256i *)(buf + i));
        __m256i notLow = _mm256_cmpeq_epi8(_mm256_max_epu8(v, vMin), v);  // unsigned b >= min
        if (allow_tab) {
            notLow = _mm256_or_si256(notLow, _mm256_cmpeq_epi8(v, vTab));
        }
        __m256i illegal = _mm256_or_si256(_mm256_xor_si256(notLow, vOnes), _mm256_cmpeq_epi8(v, vDEL));
        unsigned mask = (unsigned)_mm256_movemask_epi8(illegal);
        if (mask != 0) {
            return i + (size_t)__builtin_ctz(mask);
        }
    }
    if (i < len) {
        size_t r = adf_first_disallowed_text_scalar(buf + i, len - i, min_allowed, allow_tab);
        return (r == len - i) ? len : i + r;
    }
    return len;
}
#endif  // __x86_64__

#if defined(__aarch64__)
typedef struct {
    uint8x16_t minimum;
    uint8_t minimumByte;
    int allowTab;
} disallowed_ctx;

__attribute__((always_inline)) static inline uint8x16_t disallowed_classify(uint8x16_t v, const void *ctx) {
    const disallowed_ctx *c = (const disallowed_ctx *)ctx;
    // Unsigned b < min, but never a byte of 0x80 and over: obs-text is legal whatever `min_allowed` is.
    const uint8x16_t isLow = vandq_u8(vcltq_u8(v, c->minimum), vcltq_u8(v, vdupq_n_u8(0x80)));
    const uint8x16_t isDEL = vceqq_u8(v, vdupq_n_u8(0x7F));
    if (c->allowTab) {
        return vorrq_u8(vbicq_u8(isLow, vceqq_u8(v, vdupq_n_u8(0x09))), isDEL);  // (isLow & ~isTab) | isDEL
    }
    return vorrq_u8(isLow, isDEL);
}

__attribute__((always_inline)) static inline size_t disallowed_scalar(
    const uint8_t *buf, size_t len, const void *ctx) {
    const disallowed_ctx *c = (const disallowed_ctx *)ctx;
    return adf_first_disallowed_text_scalar(buf, len, c->minimumByte, c->allowTab);
}

static size_t disallowed_neon_impl(
    const uint8_t *buf, size_t len, uint8_t min_allowed, int allow_tab) {
    const disallowed_ctx ctx = {vdupq_n_u8(min_allowed), min_allowed, allow_tab};
    return adf_neon_scan(buf, len, disallowed_classify, disallowed_scalar, &ctx);
}
#endif  // __aarch64__

size_t adf_first_disallowed_text(const uint8_t *buf, size_t len, uint8_t min_allowed, int allow_tab) {
#if defined(__aarch64__)
    // NEON is mandatory on arm64 and every tier above it runs this kernel (adf_cpu.c), so there is
    // nothing to look up: the lookup was a pthread_once call on each scan.
    return disallowed_neon_impl(buf, len, min_allowed, allow_tab);
#else
    switch (adf_kernels_isa()) {
#if defined(__x86_64__)
        case ADF_ISA_X86_AVX512:
        case ADF_ISA_X86_AVX2:
            return disallowed_avx2_impl(buf, len, min_allowed, allow_tab);
        case ADF_ISA_X86_SSE42:
        case ADF_ISA_X86_SSE2:
            return disallowed_sse2_impl(buf, len, min_allowed, allow_tab);
#endif
        default:
            return adf_first_disallowed_text_scalar(buf, len, min_allowed, allow_tab);
    }
#endif
}

// MARK: - First control byte or literal (JSON escape-on-write)

size_t adf_index_of_control_or_any5_scalar(
    const uint8_t *buf, size_t len, uint8_t n0, uint8_t n1, uint8_t n2, uint8_t n3, uint8_t n4) {
    for (size_t i = 0; i < len; ++i) {
        uint8_t b = buf[i];
        if (b < 0x20 || b == n0 || b == n1 || b == n2 || b == n3 || b == n4) {
            return i;
        }
    }
    return len;
}

#if defined(__x86_64__)
static size_t ctrlany_sse2_impl(
    const uint8_t *buf, size_t len, uint8_t n0, uint8_t n1, uint8_t n2, uint8_t n3, uint8_t n4) {
    const __m128i vCtrl = _mm_set1_epi8(0x1F);
    const __m128i v0 = _mm_set1_epi8((char)n0), v1 = _mm_set1_epi8((char)n1);
    const __m128i v2 = _mm_set1_epi8((char)n2), v3 = _mm_set1_epi8((char)n3);
    const __m128i v4 = _mm_set1_epi8((char)n4);
    size_t i = 0;
    for (; i + 16 <= len; i += 16) {
        __m128i v = _mm_loadu_si128((const __m128i *)(buf + i));
        __m128i m = _mm_or_si128(
            _mm_cmpeq_epi8(_mm_max_epu8(v, vCtrl), vCtrl),  // b < 0x20
            _mm_or_si128(_mm_or_si128(_mm_cmpeq_epi8(v, v0), _mm_cmpeq_epi8(v, v1)),
                         _mm_or_si128(_mm_or_si128(_mm_cmpeq_epi8(v, v2), _mm_cmpeq_epi8(v, v3)),
                                      _mm_cmpeq_epi8(v, v4))));
        int mask = _mm_movemask_epi8(m);
        if (mask != 0) {
            return i + (size_t)__builtin_ctz((unsigned)mask);
        }
    }
    if (i < len) {
        size_t r = adf_index_of_control_or_any5_scalar(buf + i, len - i, n0, n1, n2, n3, n4);
        return (r == len - i) ? len : i + r;
    }
    return len;
}

__attribute__((target("avx2")))
static size_t ctrlany_avx2_impl(
    const uint8_t *buf, size_t len, uint8_t n0, uint8_t n1, uint8_t n2, uint8_t n3, uint8_t n4) {
    const __m256i vCtrl = _mm256_set1_epi8(0x1F);
    const __m256i v0 = _mm256_set1_epi8((char)n0), v1 = _mm256_set1_epi8((char)n1);
    const __m256i v2 = _mm256_set1_epi8((char)n2), v3 = _mm256_set1_epi8((char)n3);
    const __m256i v4 = _mm256_set1_epi8((char)n4);
    size_t i = 0;
    for (; i + 32 <= len; i += 32) {
        __m256i v = _mm256_loadu_si256((const __m256i *)(buf + i));
        __m256i m = _mm256_or_si256(
            _mm256_cmpeq_epi8(_mm256_max_epu8(v, vCtrl), vCtrl),
            _mm256_or_si256(_mm256_or_si256(_mm256_cmpeq_epi8(v, v0), _mm256_cmpeq_epi8(v, v1)),
                            _mm256_or_si256(_mm256_or_si256(_mm256_cmpeq_epi8(v, v2),
                                                            _mm256_cmpeq_epi8(v, v3)),
                                            _mm256_cmpeq_epi8(v, v4))));
        unsigned mask = (unsigned)_mm256_movemask_epi8(m);
        if (mask != 0) {
            return i + (size_t)__builtin_ctz(mask);
        }
    }
    if (i < len) {
        size_t r = adf_index_of_control_or_any5_scalar(buf + i, len - i, n0, n1, n2, n3, n4);
        return (r == len - i) ? len : i + r;
    }
    return len;
}
#endif  // __x86_64__

#if defined(__aarch64__)
__attribute__((always_inline)) static inline uint8x16_t ctrlany_classify(uint8x16_t v, const void *ctx) {
    return vorrq_u8(vcleq_u8(v, vdupq_n_u8(0x1F)), any5_classify(v, ctx));  // b <= 0x1F, or a needle
}

__attribute__((always_inline)) static inline size_t ctrlany_scalar(const uint8_t *buf, size_t len, const void *ctx) {
    const any5_ctx *c = (const any5_ctx *)ctx;
    return adf_index_of_control_or_any5_scalar(buf, len, c->byte[0], c->byte[1], c->byte[2], c->byte[3], c->byte[4]);
}

static size_t ctrlany_neon_impl(
    const uint8_t *buf, size_t len, uint8_t n0, uint8_t n1, uint8_t n2, uint8_t n3, uint8_t n4) {
    const any5_ctx ctx = {
        {vdupq_n_u8(n0), vdupq_n_u8(n1), vdupq_n_u8(n2), vdupq_n_u8(n3), vdupq_n_u8(n4)}, {n0, n1, n2, n3, n4}};
    return adf_neon_scan(buf, len, ctrlany_classify, ctrlany_scalar, &ctx);
}
#endif  // __aarch64__

size_t adf_index_of_control_or_any5(
    const uint8_t *buf, size_t len, uint8_t n0, uint8_t n1, uint8_t n2, uint8_t n3, uint8_t n4) {
#if defined(__aarch64__)
    // NEON is mandatory on arm64 and every tier above it runs this kernel (adf_cpu.c), so there is
    // nothing to look up: the lookup was a pthread_once call on each scan.
    return ctrlany_neon_impl(buf, len, n0, n1, n2, n3, n4);
#else
    switch (adf_kernels_isa()) {
#if defined(__x86_64__)
        case ADF_ISA_X86_AVX512:
        case ADF_ISA_X86_AVX2:
            return ctrlany_avx2_impl(buf, len, n0, n1, n2, n3, n4);
        case ADF_ISA_X86_SSE42:
        case ADF_ISA_X86_SSE2:
            return ctrlany_sse2_impl(buf, len, n0, n1, n2, n3, n4);
#endif
        default:
            return adf_index_of_control_or_any5_scalar(buf, len, n0, n1, n2, n3, n4);
    }
#endif
}

// MARK: - Single-byte search (memchr-backed)

size_t adf_index_of_byte(const uint8_t *buf, size_t len, uint8_t needle) {
    if (len == 0) {
        return 0;
    }
    const void *hit = memchr(buf, needle, len);
    return hit ? (size_t)((const uint8_t *)hit - buf) : len;
}

size_t adf_index_of_byte_scalar(const uint8_t *buf, size_t len, uint8_t needle) {
    for (size_t i = 0; i < len; ++i) {
        if (buf[i] == needle) {
            return i;
        }
    }
    return len;
}

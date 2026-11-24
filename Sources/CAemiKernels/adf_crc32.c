//
//  adf_crc32.c
//  CAemiKernels
//
//  IEEE 802.3 / ISO-HDLC / gzip CRC-32 (RFC 1952 §8; reflected polynomial 0xEDB88320), raw update.
//  Promoted from g-cqd/HTTP (`CCRC32`) into `CAemiKernels` alongside `adf_crc32c.c`:
//    • arm64: ARMv8 CRC32 instructions (`__crc32d`/`__crc32w`/`__crc32h`/`__crc32b`).
//    • x86-64 / i686: CPUID-dispatched PCLMULQDQ 4-way 128-bit folding + Barrett reduction.
//    • portable fallback & oracle: slicing-by-8 lookup tables (initialized once via pthread_once).
//  Raw update contract matches `adf_crc32c_update`: caller supplies initial state (e.g. 0xFFFFFFFFu)
//  and performs final inversion (^ 0xFFFFFFFFu).
//

#include "CAemiKernels.h"

#include <pthread.h>
#include <string.h>

// MARK: - Portable slicing-by-8 table

static uint32_t kIEEE[8][256];
static pthread_once_t kIEEEOnce = PTHREAD_ONCE_INIT;

static void build_ieee_tables(void) {
    for (int n = 0; n < 256; ++n) {
        uint32_t c = (uint32_t)n;
        for (int k = 0; k < 8; ++k) {
            c = (c & 1u) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
        }
        kIEEE[0][n] = c;
    }
    for (int n = 0; n < 256; ++n) {
        uint32_t c = kIEEE[0][n];
        for (int k = 1; k < 8; ++k) {
            c = kIEEE[0][c & 0xFFu] ^ (c >> 8);
            kIEEE[k][n] = c;
        }
    }
}

static inline uint32_t ieee_load_le32(const uint8_t *p) {
    uint32_t v;
    memcpy(&v, p, 4);
    return v;
}

uint32_t adf_crc32_ieee_update_scalar(uint32_t crc, const uint8_t *buf, size_t len) {
    pthread_once(&kIEEEOnce, build_ieee_tables);
    while (len >= 8) {
        crc ^= ieee_load_le32(buf);
        uint32_t hi = ieee_load_le32(buf + 4);
        crc = kIEEE[7][crc & 0xFFu] ^ kIEEE[6][(crc >> 8) & 0xFFu]
            ^ kIEEE[5][(crc >> 16) & 0xFFu] ^ kIEEE[4][(crc >> 24) & 0xFFu]
            ^ kIEEE[3][hi & 0xFFu] ^ kIEEE[2][(hi >> 8) & 0xFFu]
            ^ kIEEE[1][(hi >> 16) & 0xFFu] ^ kIEEE[0][(hi >> 24) & 0xFFu];
        buf += 8;
        len -= 8;
    }
    while (len--) {
        crc = kIEEE[0][(crc ^ *buf++) & 0xFFu] ^ (crc >> 8);
    }
    return crc;
}

// MARK: - ARMv8 CRC32

#if defined(__aarch64__)
#include <arm_acle.h>
#include <arm_neon.h>

__attribute__((target("+crc")))
static uint32_t crc32_ieee_arm_fold(uint32_t crc, const uint8_t *buf, size_t len) {
    while (len >= 8) {
        uint64_t v;
        memcpy(&v, buf, 8);
        crc = __crc32d(crc, v);
        buf += 8;
        len -= 8;
    }
    if (len & 4) {
        uint32_t v;
        memcpy(&v, buf, 4);
        crc = __crc32w(crc, v);
        buf += 4;
    }
    if (len & 2) {
        uint16_t v;
        memcpy(&v, buf, 2);
        crc = __crc32h(crc, v);
        buf += 2;
    }
    if (len & 1) {
        crc = __crc32b(crc, *buf);
    }
    return crc;
}
#endif

// MARK: - x86 PCLMULQDQ folding

#if defined(__x86_64__) || defined(__i386__)
#include <cpuid.h>
#include <immintrin.h>

static int kIEEEHasPCLMUL = 0;
static pthread_once_t kIEEECPUIDOnce = PTHREAD_ONCE_INIT;

static void detect_ieee_x86_features(void) {
    unsigned int eax = 0, ebx = 0, ecx = 0, edx = 0;
    if (__get_cpuid(1, &eax, &ebx, &ecx, &edx) == 0) {
        return;
    }
    kIEEEHasPCLMUL = ((ecx & (1u << 1)) != 0) && ((edx & (1u << 26)) != 0);
}

static int ieee_x86_has_pclmul(void) {
    pthread_once(&kIEEECPUIDOnce, detect_ieee_x86_features);
    return kIEEEHasPCLMUL;
}

static const uint64_t kFoldBy4[2] __attribute__((aligned(16))) = {
    0x0154442BD4ULL,
    0x01C6E41596ULL,
};
static const uint64_t kFoldBy1[2] __attribute__((aligned(16))) = {
    0x01751997D0ULL,
    0x00CCAA009EULL,
};
static const uint64_t kFold64[2] __attribute__((aligned(16))) = {
    0x0163CD6124ULL,
    0,
};
static const uint64_t kBarrett[2] __attribute__((aligned(16))) = {
    0x01DB710641ULL,
    0x01F7011641ULL,
};

__attribute__((always_inline, target("sse2,pclmul")))
static inline __m128i ieee_fold_step(__m128i x, __m128i next, __m128i k) {
    __m128i lo = _mm_clmulepi64_si128(x, k, 0x00);
    __m128i hi = _mm_clmulepi64_si128(x, k, 0x11);
    return _mm_xor_si128(_mm_xor_si128(lo, hi), next);
}

__attribute__((target("sse2,pclmul")))
static uint32_t crc32_ieee_pclmul_fold(uint32_t crc, const uint8_t *buf, size_t len) {
    const __m128i k4 = _mm_load_si128((const __m128i *)(const void *)kFoldBy4);
    const __m128i k1 = _mm_load_si128((const __m128i *)(const void *)kFoldBy1);
    __m128i x1 = _mm_loadu_si128((const __m128i *)(const void *)(buf + 0));
    __m128i x2 = _mm_loadu_si128((const __m128i *)(const void *)(buf + 16));
    __m128i x3 = _mm_loadu_si128((const __m128i *)(const void *)(buf + 32));
    __m128i x4 = _mm_loadu_si128((const __m128i *)(const void *)(buf + 48));
    x1 = _mm_xor_si128(x1, _mm_cvtsi32_si128((int)crc));
    buf += 64;
    len -= 64;
    while (len >= 64) {
        x1 = ieee_fold_step(x1, _mm_loadu_si128((const __m128i *)(const void *)(buf + 0)), k4);
        x2 = ieee_fold_step(x2, _mm_loadu_si128((const __m128i *)(const void *)(buf + 16)), k4);
        x3 = ieee_fold_step(x3, _mm_loadu_si128((const __m128i *)(const void *)(buf + 32)), k4);
        x4 = ieee_fold_step(x4, _mm_loadu_si128((const __m128i *)(const void *)(buf + 48)), k4);
        buf += 64;
        len -= 64;
    }
    x1 = ieee_fold_step(x1, x2, k1);
    x1 = ieee_fold_step(x1, x3, k1);
    x1 = ieee_fold_step(x1, x4, k1);
    while (len >= 16) {
        x1 = ieee_fold_step(x1, _mm_loadu_si128((const __m128i *)(const void *)buf), k1);
        buf += 16;
        len -= 16;
    }
    __m128i t = _mm_clmulepi64_si128(x1, k1, 0x10);
    x1 = _mm_xor_si128(_mm_srli_si128(x1, 8), t);
    const __m128i mask32 = _mm_set_epi32(0, 0, 0, -1);
    const __m128i k5 = _mm_load_si128((const __m128i *)(const void *)kFold64);
    t = _mm_srli_si128(x1, 4);
    x1 = _mm_and_si128(x1, mask32);
    x1 = _mm_clmulepi64_si128(x1, k5, 0x00);
    x1 = _mm_xor_si128(x1, t);
    const __m128i br = _mm_load_si128((const __m128i *)(const void *)kBarrett);
    t = _mm_and_si128(x1, mask32);
    t = _mm_clmulepi64_si128(t, br, 0x10);
    t = _mm_and_si128(t, mask32);
    t = _mm_clmulepi64_si128(t, br, 0x00);
    x1 = _mm_xor_si128(x1, t);
    return (uint32_t)_mm_cvtsi128_si32(_mm_srli_si128(x1, 4));
}

static uint32_t crc32_ieee_x86_fold(uint32_t crc, const uint8_t *buf, size_t len) {
    if (len >= 64 && ieee_x86_has_pclmul()) {
        size_t vector_len = len & ~(size_t)15;
        crc = crc32_ieee_pclmul_fold(crc, buf, vector_len);
        buf += vector_len;
        len -= vector_len;
    }
    return adf_crc32_ieee_update_scalar(crc, buf, len);
}
#endif

uint32_t adf_crc32_ieee_update(uint32_t crc, const uint8_t *buf, size_t len) {
    if (buf == NULL || len == 0) {
        return crc;
    }
#if defined(__aarch64__)
    return crc32_ieee_arm_fold(crc, buf, len);
#elif defined(__x86_64__) || defined(__i386__)
    return crc32_ieee_x86_fold(crc, buf, len);
#else
    return adf_crc32_ieee_update_scalar(crc, buf, len);
#endif
}

// MARK: - 4-byte repeating XOR mask (RFC 6455 WebSocket masking, NEON / SSE2 / scalar)

void adf_xor_mask4_scalar(uint8_t *buf, size_t len, const uint8_t mask[4]) {
    if (buf == NULL || len == 0) {
        return;
    }
    for (size_t i = 0; i < len; ++i) {
        buf[i] ^= mask[i & 3u];
    }
}

void adf_xor_mask4(uint8_t *buf, size_t len, const uint8_t mask[4]) {
    if (buf == NULL || len == 0) {
        return;
    }
    uint32_t m32;
    memcpy(&m32, mask, 4);
#if defined(__aarch64__)
    if (len >= 16) {
        uint8x16_t vm = vreinterpretq_u8_u32(vdupq_n_u32(m32));
        while (len >= 64) {
            uint8x16_t v0 = veorq_u8(vld1q_u8(buf + 0), vm);
            uint8x16_t v1 = veorq_u8(vld1q_u8(buf + 16), vm);
            uint8x16_t v2 = veorq_u8(vld1q_u8(buf + 32), vm);
            uint8x16_t v3 = veorq_u8(vld1q_u8(buf + 48), vm);
            vst1q_u8(buf + 0, v0);
            vst1q_u8(buf + 16, v1);
            vst1q_u8(buf + 32, v2);
            vst1q_u8(buf + 48, v3);
            buf += 64;
            len -= 64;
        }
        while (len >= 16) {
            vst1q_u8(buf, veorq_u8(vld1q_u8(buf), vm));
            buf += 16;
            len -= 16;
        }
    }
#elif defined(__x86_64__) || defined(__i386__)
    if (len >= 16) {
        __m128i vm = _mm_set1_epi32((int)m32);
        while (len >= 64) {
            _mm_storeu_si128((__m128i *)(void *)(buf + 0), _mm_xor_si128(_mm_loadu_si128((const __m128i *)(const void *)(buf + 0)), vm));
            _mm_storeu_si128((__m128i *)(void *)(buf + 16), _mm_xor_si128(_mm_loadu_si128((const __m128i *)(const void *)(buf + 16)), vm));
            _mm_storeu_si128((__m128i *)(void *)(buf + 32), _mm_xor_si128(_mm_loadu_si128((const __m128i *)(const void *)(buf + 32)), vm));
            _mm_storeu_si128((__m128i *)(void *)(buf + 48), _mm_xor_si128(_mm_loadu_si128((const __m128i *)(const void *)(buf + 48)), vm));
            buf += 64;
            len -= 64;
        }
        while (len >= 16) {
            _mm_storeu_si128((__m128i *)(void *)buf, _mm_xor_si128(_mm_loadu_si128((const __m128i *)(const void *)buf), vm));
            buf += 16;
            len -= 16;
        }
    }
#endif
    while (len >= 4) {
        uint32_t w;
        memcpy(&w, buf, 4);
        w ^= m32;
        memcpy(buf, &w, 4);
        buf += 4;
        len -= 4;
    }
    for (size_t i = 0; i < len; ++i) {
        buf[i] ^= mask[i];
    }
}

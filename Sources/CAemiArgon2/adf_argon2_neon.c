//
//  adf_argon2_neon.c
//  CAemiArgon2
//
//  G and BLAKE2b's F on NEON: two words per register, so RFC 9106's P runs as four GB at once in two halves, the diagonal
//  step reached by `ext`. BlaMka's product is `umull` of the narrowed halves. Rotations: by 32 a `rev64` of 32-bit lanes,
//  by 24 and 16 a byte table, by 63 a shift and an insert; with SHA3 each xor and rotation is one `xar`. The same source
//  builds both, so they cannot drift. Constant time: no branch or lookup depends on the data.
//

#include "adf_argon2_internal.h"

#if defined(__aarch64__)
#include <arm_neon.h>

#if !defined(__ARM_FEATURE_SHA3) && defined(__clang__)
#define ADF_SHA3_TARGET __attribute__((target("sha3")))
#elif !defined(__ARM_FEATURE_SHA3)
#define ADF_SHA3_TARGET __attribute__((target("+sha3")))
#else
#define ADF_SHA3_TARGET
#endif

static const uint8_t rot24_table[16] = {3, 4, 5, 6, 7, 0, 1, 2, 11, 12, 13, 14, 15, 8, 9, 10};
static const uint8_t rot16_table[16] = {2, 3, 4, 5, 6, 7, 0, 1, 10, 11, 12, 13, 14, 15, 8, 9};

#define ADF_XOR_ROTR_PLAIN(x, y, n) adf_rotr_##n(veorq_u64((x), (y)))
#define ADF_XOR_ROTR_SHA3(x, y, n) vxarq_u64((x), (y), (n))

static inline uint64x2_t adf_rotr_32(uint64x2_t x) {
    return vreinterpretq_u64_u32(vrev64q_u32(vreinterpretq_u32_u64(x)));
}
static inline uint64x2_t adf_rotr_24(uint64x2_t x) {
    return vreinterpretq_u64_u8(vqtbl1q_u8(vreinterpretq_u8_u64(x), vld1q_u8(rot24_table)));
}
static inline uint64x2_t adf_rotr_16(uint64x2_t x) {
    return vreinterpretq_u64_u8(vqtbl1q_u8(vreinterpretq_u8_u64(x), vld1q_u8(rot16_table)));
}
static inline uint64x2_t adf_rotr_63(uint64x2_t x) {
    return vsriq_n_u64(vshlq_n_u64(x, 1), x, 63);
}

static inline uint64x2_t adf_blamka(uint64x2_t x, uint64x2_t y) {
    const uint64x2_t product = vmull_u32(vmovn_u64(x), vmovn_u64(y));
    return vaddq_u64(vaddq_u64(x, y), vaddq_u64(product, product));
}

/// Four GB at once over the pairs (a0, b0, c0, d0) and (a1, b1, c1, d1); `XR` is the xor-and-rotate.
#define ADF_GB2(XR, a0, b0, c0, d0, a1, b1, c1, d1)                                                                    \
    do {                                                                                                               \
        a0 = adf_blamka(a0, b0);                                                                                       \
        a1 = adf_blamka(a1, b1);                                                                                       \
        d0 = XR(d0, a0, 32);                                                                                           \
        d1 = XR(d1, a1, 32);                                                                                           \
        c0 = adf_blamka(c0, d0);                                                                                       \
        c1 = adf_blamka(c1, d1);                                                                                       \
        b0 = XR(b0, c0, 24);                                                                                           \
        b1 = XR(b1, c1, 24);                                                                                           \
        a0 = adf_blamka(a0, b0);                                                                                       \
        a1 = adf_blamka(a1, b1);                                                                                       \
        d0 = XR(d0, a0, 16);                                                                                           \
        d1 = XR(d1, a1, 16);                                                                                           \
        c0 = adf_blamka(c0, d0);                                                                                       \
        c1 = adf_blamka(c1, d1);                                                                                       \
        b0 = XR(b0, c0, 63);                                                                                           \
        b1 = XR(b1, c1, 63);                                                                                           \
    } while (0)

/// RFC 9106's P over eight registers, the sixteen words in order: columns, then diagonals, then back.
#define ADF_P(XR, r0, r1, r2, r3, r4, r5, r6, r7)                                                                      \
    do {                                                                                                               \
        ADF_GB2(XR, r0, r2, r4, r6, r1, r3, r5, r7);                                                                   \
        uint64x2_t b0 = vextq_u64(r2, r3, 1), b1 = vextq_u64(r3, r2, 1);                                               \
        uint64x2_t c0 = r5, c1 = r4;                                                                                   \
        uint64x2_t d0 = vextq_u64(r7, r6, 1), d1 = vextq_u64(r6, r7, 1);                                               \
        ADF_GB2(XR, r0, b0, c0, d0, r1, b1, c1, d1);                                                                   \
        r2 = vextq_u64(b1, b0, 1);                                                                                     \
        r3 = vextq_u64(b0, b1, 1);                                                                                     \
        r4 = c1;                                                                                                       \
        r5 = c0;                                                                                                       \
        r6 = vextq_u64(d0, d1, 1);                                                                                     \
        r7 = vextq_u64(d1, d0, 1);                                                                                     \
    } while (0)

/// G over whole blocks: R = prev ^ ref in 64 registers' worth, P on each row (eight consecutive registers), P on each
/// column (every eighth register), then next = P(R) ^ R, xored into next after the first pass.
#define ADF_BLOCK(XR)                                                                                                  \
    uint64x2_t r[64], z[64];                                                                                           \
    for (size_t index = 0; index < 64; index++) {                                                                      \
        r[index] = veorq_u64(vld1q_u64(prev + 2 * index), vld1q_u64(ref + 2 * index));                                 \
        z[index] = r[index];                                                                                           \
    }                                                                                                                  \
    for (size_t row = 0; row < 8; row++) {                                                                             \
        uint64x2_t *q = z + 8 * row;                                                                                   \
        ADF_P(XR, q[0], q[1], q[2], q[3], q[4], q[5], q[6], q[7]);                                                     \
    }                                                                                                                  \
    for (size_t column = 0; column < 8; column++) {                                                                    \
        uint64x2_t *q = z + column;                                                                                    \
        ADF_P(XR, q[0], q[8], q[16], q[24], q[32], q[40], q[48], q[56]);                                               \
    }                                                                                                                  \
    if (with_xor) {                                                                                                    \
        for (size_t index = 0; index < 64; index++) {                                                                  \
            uint64x2_t out = veorq_u64(vld1q_u64(next + 2 * index), veorq_u64(z[index], r[index]));                    \
            vst1q_u64(next + 2 * index, out);                                                                          \
        }                                                                                                              \
    } else {                                                                                                           \
        for (size_t index = 0; index < 64; index++) {                                                                  \
            vst1q_u64(next + 2 * index, veorq_u64(z[index], r[index]));                                                \
        }                                                                                                              \
    }

void adf_argon2_block_neon(uint64_t *next, const uint64_t *prev, const uint64_t *ref, int with_xor) {
    ADF_BLOCK(ADF_XOR_ROTR_PLAIN)
}

ADF_SHA3_TARGET
void adf_argon2_block_neon_sha3(uint64_t *next, const uint64_t *prev, const uint64_t *ref, int with_xor) {
    ADF_BLOCK(ADF_XOR_ROTR_SHA3)
}

// MARK: - BLAKE2b's F

static const uint64_t blake2b_iv[8] = {
    0x6a09e667f3bcc908u, 0xbb67ae8584caa73bu, 0x3c6ef372fe94f82bu, 0xa54ff53a5f1d36f1u,
    0x510e527fade682d1u, 0x9b05688c2b3e6c1fu, 0x1f83d9abfb41bd6bu, 0x5be0cd19137e2179u};

static const uint8_t sigma[12][16] = {
    {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15}, {14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3},
    {11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4}, {7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8},
    {9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13}, {2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9},
    {12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11}, {13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10},
    {6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5}, {10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0},
    {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15}, {14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3}};

static inline uint64x2_t adf_pair(const uint64_t *m, uint8_t first, uint8_t second) {
    return vcombine_u64(vcreate_u64(m[first]), vcreate_u64(m[second]));
}

/// Half a BLAKE2b round on two columns' or diagonals' pairs, with message pairs x (first add) and y (second).
#define ADF_B2_HALF(XR, a0, b0, c0, d0, a1, b1, c1, d1, x0, x1, y0, y1)                                                \
    do {                                                                                                               \
        a0 = vaddq_u64(vaddq_u64(a0, b0), x0);                                                                         \
        a1 = vaddq_u64(vaddq_u64(a1, b1), x1);                                                                         \
        d0 = XR(d0, a0, 32);                                                                                           \
        d1 = XR(d1, a1, 32);                                                                                           \
        c0 = vaddq_u64(c0, d0);                                                                                        \
        c1 = vaddq_u64(c1, d1);                                                                                        \
        b0 = XR(b0, c0, 24);                                                                                           \
        b1 = XR(b1, c1, 24);                                                                                           \
        a0 = vaddq_u64(vaddq_u64(a0, b0), y0);                                                                         \
        a1 = vaddq_u64(vaddq_u64(a1, b1), y1);                                                                         \
        d0 = XR(d0, a0, 16);                                                                                           \
        d1 = XR(d1, a1, 16);                                                                                           \
        c0 = vaddq_u64(c0, d0);                                                                                        \
        c1 = vaddq_u64(c1, d1);                                                                                        \
        b0 = XR(b0, c0, 63);                                                                                           \
        b1 = XR(b1, c1, 63);                                                                                           \
    } while (0)

#define ADF_B2_COMPRESS(XR)                                                                                            \
    uint64x2_t a0 = vld1q_u64(state), a1 = vld1q_u64(state + 2);                                                       \
    uint64x2_t b0 = vld1q_u64(state + 4), b1 = vld1q_u64(state + 6);                                                   \
    uint64x2_t c0 = vld1q_u64(blake2b_iv), c1 = vld1q_u64(blake2b_iv + 2);                                             \
    uint64x2_t d0 = veorq_u64(vld1q_u64(blake2b_iv + 4), vcombine_u64(vcreate_u64(count_low), vcreate_u64(count_high)));\
    uint64x2_t d1 = veorq_u64(vld1q_u64(blake2b_iv + 6),                                                               \
                              vcombine_u64(vcreate_u64((uint64_t)0 - (uint64_t)(last != 0)), vcreate_u64(0)));         \
    for (size_t round = 0; round < 12; round++) {                                                                      \
        const uint8_t *s = sigma[round];                                                                               \
        ADF_B2_HALF(XR, a0, b0, c0, d0, a1, b1, c1, d1, adf_pair(m, s[0], s[2]), adf_pair(m, s[4], s[6]),             \
                    adf_pair(m, s[1], s[3]), adf_pair(m, s[5], s[7]));                                                 \
        uint64x2_t e0 = vextq_u64(b0, b1, 1), e1 = vextq_u64(b1, b0, 1);                                               \
        uint64x2_t f0 = c1, f1 = c0;                                                                                   \
        uint64x2_t g0 = vextq_u64(d1, d0, 1), g1 = vextq_u64(d0, d1, 1);                                               \
        ADF_B2_HALF(XR, a0, e0, f0, g0, a1, e1, f1, g1, adf_pair(m, s[8], s[10]), adf_pair(m, s[12], s[14]),          \
                    adf_pair(m, s[9], s[11]), adf_pair(m, s[13], s[15]));                                              \
        b0 = vextq_u64(e1, e0, 1);                                                                                     \
        b1 = vextq_u64(e0, e1, 1);                                                                                     \
        c0 = f1;                                                                                                       \
        c1 = f0;                                                                                                       \
        d0 = vextq_u64(g0, g1, 1);                                                                                     \
        d1 = vextq_u64(g1, g0, 1);                                                                                     \
    }                                                                                                                  \
    vst1q_u64(state, veorq_u64(vld1q_u64(state), veorq_u64(a0, c0)));                                                  \
    vst1q_u64(state + 2, veorq_u64(vld1q_u64(state + 2), veorq_u64(a1, c1)));                                          \
    vst1q_u64(state + 4, veorq_u64(vld1q_u64(state + 4), veorq_u64(b0, d0)));                                          \
    vst1q_u64(state + 6, veorq_u64(vld1q_u64(state + 6), veorq_u64(b1, d1)));

static void adf_blake2b_neon_plain(uint64_t state[8], const uint64_t m[16], uint64_t count_low, uint64_t count_high,
                                   int last) {
    ADF_B2_COMPRESS(ADF_XOR_ROTR_PLAIN)
}

ADF_SHA3_TARGET
static void adf_blake2b_neon_sha3(uint64_t state[8], const uint64_t m[16], uint64_t count_low, uint64_t count_high,
                                  int last) {
    ADF_B2_COMPRESS(ADF_XOR_ROTR_SHA3)
}

void adf_blake2b_compress_neon(uint64_t state[8], const uint64_t block[16], uint64_t count_low, uint64_t count_high,
                               int last, int sha3) {
    if (sha3) {
        adf_blake2b_neon_sha3(state, block, count_low, count_high, last);
    } else {
        adf_blake2b_neon_plain(state, block, count_low, count_high, last);
    }
}

#endif

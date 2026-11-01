//
//  adf_argon2_scalar.c
//  CAemiArgon2
//
//  The portable references: Argon2's G with BlaMka's multiply (RFC 9106, 3.5 and 3.6) and BLAKE2b's F (RFC 7693, 3.2).
//  Only adds, multiplies, xors and rotations by constants: nothing waits on a value.
//

#include "adf_argon2_internal.h"

static inline uint64_t rotr64(uint64_t x, unsigned int n) {
    return (x >> n) | (x << (64u - n));
}

/// BlaMka: `x + y + 2 * lo32(x) * lo32(y)`, modulo 2^64.
static inline uint64_t blamka(uint64_t x, uint64_t y) {
    const uint64_t low = 0xFFFFFFFFu;
    return x + y + 2u * ((x & low) * (y & low));
}

#define ADF_GB(a, b, c, d)                                                                                             \
    do {                                                                                                               \
        a = blamka(a, b);                                                                                              \
        d = rotr64(d ^ a, 32);                                                                                         \
        c = blamka(c, d);                                                                                              \
        b = rotr64(b ^ c, 24);                                                                                         \
        a = blamka(a, b);                                                                                              \
        d = rotr64(d ^ a, 16);                                                                                         \
        c = blamka(c, d);                                                                                              \
        b = rotr64(b ^ c, 63);                                                                                         \
    } while (0)

/// RFC 9106's P over sixteen words, given by their indexes in `z`.
static inline void permute(uint64_t *z, const size_t *at) {
    uint64_t v[16];
    for (size_t index = 0; index < 16; index++) {
        v[index] = z[at[index]];
    }
    ADF_GB(v[0], v[4], v[8], v[12]);
    ADF_GB(v[1], v[5], v[9], v[13]);
    ADF_GB(v[2], v[6], v[10], v[14]);
    ADF_GB(v[3], v[7], v[11], v[15]);
    ADF_GB(v[0], v[5], v[10], v[15]);
    ADF_GB(v[1], v[6], v[11], v[12]);
    ADF_GB(v[2], v[7], v[8], v[13]);
    ADF_GB(v[3], v[4], v[9], v[14]);
    for (size_t index = 0; index < 16; index++) {
        z[at[index]] = v[index];
    }
}

void adf_argon2_block_scalar(uint64_t *next, const uint64_t *prev, const uint64_t *ref, int with_xor) {
    uint64_t r[128], z[128];
    for (size_t index = 0; index < 128; index++) {
        r[index] = prev[index] ^ ref[index];
        z[index] = r[index];
    }
    size_t at[16];
    for (size_t row = 0; row < 8; row++) {
        for (size_t index = 0; index < 16; index++) {
            at[index] = 16 * row + index;
        }
        permute(z, at);
    }
    for (size_t column = 0; column < 8; column++) {
        for (size_t pair = 0; pair < 8; pair++) {
            at[2 * pair] = 2 * column + 16 * pair;
            at[2 * pair + 1] = 2 * column + 16 * pair + 1;
        }
        permute(z, at);
    }
    for (size_t index = 0; index < 128; index++) {
        next[index] = with_xor ? next[index] ^ z[index] ^ r[index] : z[index] ^ r[index];
    }
}

static const uint64_t blake2b_iv[8] = {
    0x6a09e667f3bcc908u, 0xbb67ae8584caa73bu, 0x3c6ef372fe94f82bu, 0xa54ff53a5f1d36f1u,
    0x510e527fade682d1u, 0x9b05688c2b3e6c1fu, 0x1f83d9abfb41bd6bu, 0x5be0cd19137e2179u};

/// The message schedule: public, so indexing by it reveals nothing.
static const uint8_t sigma[12][16] = {
    {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15}, {14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3},
    {11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4}, {7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8},
    {9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13}, {2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9},
    {12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11}, {13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10},
    {6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5}, {10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0},
    {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15}, {14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3}};

#define ADF_B2_G(r, i, a, b, c, d)                                                                                     \
    do {                                                                                                               \
        a = a + b + m[sigma[r][2 * (i)]];                                                                              \
        d = rotr64(d ^ a, 32);                                                                                         \
        c = c + d;                                                                                                     \
        b = rotr64(b ^ c, 24);                                                                                         \
        a = a + b + m[sigma[r][2 * (i) + 1]];                                                                          \
        d = rotr64(d ^ a, 16);                                                                                         \
        c = c + d;                                                                                                     \
        b = rotr64(b ^ c, 63);                                                                                         \
    } while (0)

void adf_blake2b_compress_scalar(uint64_t state[8], const uint64_t m[16], uint64_t count_low, uint64_t count_high,
                                 int last) {
    uint64_t v[16];
    for (size_t index = 0; index < 8; index++) {
        v[index] = state[index];
        v[index + 8] = blake2b_iv[index];
    }
    v[12] ^= count_low;
    v[13] ^= count_high;
    v[14] ^= (uint64_t)0 - (uint64_t)(last != 0);
    for (size_t round = 0; round < 12; round++) {
        ADF_B2_G(round, 0, v[0], v[4], v[8], v[12]);
        ADF_B2_G(round, 1, v[1], v[5], v[9], v[13]);
        ADF_B2_G(round, 2, v[2], v[6], v[10], v[14]);
        ADF_B2_G(round, 3, v[3], v[7], v[11], v[15]);
        ADF_B2_G(round, 4, v[0], v[5], v[10], v[15]);
        ADF_B2_G(round, 5, v[1], v[6], v[11], v[12]);
        ADF_B2_G(round, 6, v[2], v[7], v[8], v[13]);
        ADF_B2_G(round, 7, v[3], v[4], v[9], v[14]);
    }
    for (size_t index = 0; index < 8; index++) {
        state[index] ^= v[index] ^ v[index + 8];
    }
    adf_crypto_wipe(v, sizeof v);
}

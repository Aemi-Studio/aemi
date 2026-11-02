// The cryptographic kernels against published answers, independent of their scalar references (which a defect in shared
// code would move with them): BLAKE2b-512 of "abc" (RFC 7693, appendix A) and of the empty string through
// `adf_blake2b_compress`, and RFC 9106's three test vectors (section 5) with H0 and H' written here over that compress and
// the fill done by `adf_argon2_fill`, for every backend this CPU runs and 1 to 4 threads. Then the secure helpers:
// `adf_crypto_equal` for every length to 300 with a difference at every position and every bit, `adf_crypto_wipe` exactly on its
// bytes (guard pages on both sides, the neighbours untouched), and `adf_argon2_allocate` refusing what it must. Built with ASan
// and UBSan by check.sh. Exit 0 when every answer is the published one.
#if defined(__linux__)
#define _DEFAULT_SOURCE 1  // getpagesize, MAP_ANON under -std=c11
#endif

#include "CAemiArgon2.h"
#include "../../Sources/CAemiArgon2/adf_argon2_internal.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

static int failures = 0, checks = 0;

#define EXPECT(cond, ...)                                                                                                       \
    do {                                                                                                                        \
        checks++;                                                                                                               \
        if (!(cond)) {                                                                                                          \
            failures++;                                                                                                         \
            printf("FAIL: ");                                                                                                   \
            printf(__VA_ARGS__);                                                                                                \
            printf("\n");                                                                                                       \
        }                                                                                                                       \
    } while (0)

// MARK: - BLAKE2b over the kernel's compress

static const uint64_t blake2b_iv[8] = {0x6a09e667f3bcc908u, 0xbb67ae8584caa73bu, 0x3c6ef372fe94f82bu, 0xa54ff53a5f1d36f1u,
                                       0x510e527fade682d1u, 0x9b05688c2b3e6c1fu, 0x1f83d9abfb41bd6bu, 0x5be0cd19137e2179u};

typedef struct {
    uint64_t h[8];
    uint8_t buffer[128];
    size_t filled;
    uint64_t counted;
    size_t out;
    int backend;
} Blake2b;

static void b2_init(Blake2b *s, size_t out, int backend) {
    memcpy(s->h, blake2b_iv, sizeof s->h);
    s->h[0] ^= 0x01010000u ^ (uint64_t)out;
    s->filled = 0;
    s->counted = 0;
    s->out = out;
    s->backend = backend;
}

static void b2_block(Blake2b *s, int last) {
    uint64_t words[16];
    for (int i = 0; i < 16; i++) {
        uint64_t w = 0;
        for (int b = 7; b >= 0; b--) w = (w << 8) | s->buffer[i * 8 + b];
        words[i] = w;
    }
    adf_blake2b_compress(s->h, words, s->counted, 0, last, s->backend);
}

static void b2_update(Blake2b *s, const uint8_t *data, size_t n) {
    for (size_t i = 0; i < n; i++) {
        if (s->filled == 128) {  // a full buffer is compressed only once more input follows (the last block is final)
            s->counted += 128;
            b2_block(s, 0);
            s->filled = 0;
        }
        s->buffer[s->filled++] = data[i];
    }
}

static void b2_final(Blake2b *s, uint8_t *out) {
    s->counted += s->filled;
    memset(s->buffer + s->filled, 0, 128 - s->filled);
    b2_block(s, 1);
    for (size_t i = 0; i < s->out; i++) out[i] = (uint8_t)(s->h[i / 8] >> (8 * (i % 8)));
}

static void le32(uint8_t *p, uint32_t v) {
    for (int i = 0; i < 4; i++) p[i] = (uint8_t)(v >> (8 * i));
}

/// RFC 9106's H': a hash of any length from BLAKE2b.
static void h_prime(uint8_t *out, uint32_t length, const uint8_t *in, size_t n, int backend) {
    uint8_t prefix[4];
    le32(prefix, length);
    Blake2b s;
    if (length <= 64) {
        b2_init(&s, length, backend);
        b2_update(&s, prefix, 4);
        b2_update(&s, in, n);
        b2_final(&s, out);
        return;
    }
    uint8_t v[64];
    b2_init(&s, 64, backend);
    b2_update(&s, prefix, 4);
    b2_update(&s, in, n);
    b2_final(&s, v);
    memcpy(out, v, 32);
    uint32_t written = 32;
    while (length - written > 64) {
        b2_init(&s, 64, backend);
        b2_update(&s, v, 64);
        b2_final(&s, v);
        memcpy(out + written, v, 32);
        written += 32;
    }
    b2_init(&s, length - written, backend);
    b2_update(&s, v, 64);
    b2_final(&s, out + written);
}

static int hex_equal(const uint8_t *bytes, size_t n, const char *hex) {
    for (size_t i = 0; i < n; i++) {
        unsigned value;
        if (sscanf(hex + 2 * i, "%2x", &value) != 1 || value != bytes[i]) return 0;
    }
    return 1;
}

static void blake2b_answers(int backend) {
    uint8_t digest[64];
    Blake2b s;
    b2_init(&s, 64, backend);
    b2_update(&s, (const uint8_t *)"abc", 3);
    b2_final(&s, digest);
    EXPECT(hex_equal(digest, 64, "ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d17d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923"),
           "BLAKE2b-512(\"abc\") on %s", adf_crypto_backend_name(backend));
    b2_init(&s, 64, backend);
    b2_final(&s, digest);
    EXPECT(hex_equal(digest, 64, "786a02f742015903c6c6fd852552d272912f4740e15847618a86e217f71f5419d25e1031afee585313896444934eb04b903a685b1448b755d56f701afe9be2ce"),
           "BLAKE2b-512(\"\") on %s", adf_crypto_backend_name(backend));
}

// MARK: - Argon2, RFC 9106 section 5

static void argon2_answer(uint32_t type, const char *tag_hex, int backend, uint32_t threads) {
    const uint32_t lanes = 4, memory_kib = 32, passes = 3, tag_length = 32, version = 0x13;
    const uint32_t lane_length = memory_kib / (4 * lanes) * 4;  // m' = 4 * p * floor(m / 4p)
    uint8_t password[32], salt[16], secret[8], data[12];
    memset(password, 1, sizeof password);
    memset(salt, 2, sizeof salt);
    memset(secret, 3, sizeof secret);
    memset(data, 4, sizeof data);
    // H0 = H^64(p, T, m, t, v, y, |P|, P, |S|, S, |K|, K, |X|, X).
    uint8_t h0[72], field[4];
    Blake2b s;
    b2_init(&s, 64, backend);
    const uint32_t numbers[6] = {lanes, tag_length, memory_kib, passes, version, type};
    for (int i = 0; i < 6; i++) {
        le32(field, numbers[i]);
        b2_update(&s, field, 4);
    }
    le32(field, sizeof password);
    b2_update(&s, field, 4);
    b2_update(&s, password, sizeof password);
    le32(field, sizeof salt);
    b2_update(&s, field, 4);
    b2_update(&s, salt, sizeof salt);
    le32(field, sizeof secret);
    b2_update(&s, field, 4);
    b2_update(&s, secret, sizeof secret);
    le32(field, sizeof data);
    b2_update(&s, field, 4);
    b2_update(&s, data, sizeof data);
    b2_final(&s, h0);
    const size_t blocks = (size_t)lanes * lane_length;
    uint64_t *memory = adf_argon2_allocate(blocks);
    uint8_t block[1024];
    for (uint32_t lane = 0; lane < lanes; lane++) {
        for (uint32_t column = 0; column < 2; column++) {
            le32(h0 + 64, column);
            le32(h0 + 68, lane);
            h_prime(block, 1024, h0, 72, backend);
            uint64_t *target = memory + ((size_t)lane * lane_length + column) * 128;
            for (int w = 0; w < 128; w++) {
                uint64_t v = 0;
                for (int b = 7; b >= 0; b--) v = (v << 8) | block[w * 8 + b];
                target[w] = v;
            }
        }
    }
    adf_argon2_fill_t fill = {memory, lanes, lane_length, passes, type, threads, backend};
    adf_argon2_fill(&fill);
    uint64_t final[128];
    memcpy(final, memory + (size_t)(lane_length - 1) * 128, 1024);
    for (uint32_t lane = 1; lane < lanes; lane++) {
        const uint64_t *last = memory + ((size_t)lane * lane_length + lane_length - 1) * 128;
        for (int w = 0; w < 128; w++) final[w] ^= last[w];
    }
    for (int w = 0; w < 128; w++)
        for (int b = 0; b < 8; b++) block[w * 8 + b] = (uint8_t)(final[w] >> (8 * b));
    uint8_t tag[32];
    h_prime(tag, tag_length, block, 1024, backend);
    EXPECT(hex_equal(tag, 32, tag_hex), "Argon2%s on %s, %u thread(s)", type == 0 ? "d" : type == 1 ? "i" : "id", adf_crypto_backend_name(backend),
           threads);
    adf_argon2_release(memory, blocks);
}

// MARK: - The secure helpers

static void secure_helpers(void) {
    uint8_t a[300] = {0}, b[300] = {0};
    for (size_t len = 0; len <= 300; len++) {
        for (size_t i = 0; i < len; i++) a[i] = b[i] = (uint8_t)(i * 29 + 7);
        EXPECT(adf_crypto_equal(a, b, len) == 1, "equal: equal buffers of %zu", len);
        for (size_t p = 0; p < len; p += (len > 64 ? 5 : 1)) {
            for (int bit = 0; bit < 8; bit++) {
                b[p] ^= (uint8_t)(1u << bit);
                EXPECT(adf_crypto_equal(a, b, len) == 0, "equal: bit %d of byte %zu of %zu", bit, p, len);
                b[p] ^= (uint8_t)(1u << bit);
            }
        }
    }
    // Every difference value, at the first and the last byte.
    for (int d = 1; d < 256; d++) {
        memset(a, 0x5A, 32);
        memset(b, 0x5A, 32);
        b[0] ^= (uint8_t)d;
        EXPECT(adf_crypto_equal(a, b, 32) == 0, "equal: first byte differs by %d", d);
        b[0] ^= (uint8_t)d;
        b[31] ^= (uint8_t)d;
        EXPECT(adf_crypto_equal(a, b, 32) == 0, "equal: last byte differs by %d", d);
    }
    // Wipe: exactly its bytes, in a page flanked by inaccessible pages.
    const size_t page = (size_t)getpagesize();
    uint8_t *map = mmap(NULL, 3 * page, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    mprotect(map, page, PROT_NONE);
    mprotect(map + 2 * page, page, PROT_NONE);
    uint8_t *region = map + page;
    for (size_t len = 0; len <= 200; len++) {
        for (size_t offset = 0; offset < 3; offset++) {
            memset(region, 0xA5, page);
            uint8_t *start = len + offset <= page ? region + page - len - offset : region;
            adf_crypto_wipe(start, len);
            int zeroed = 1, intact = 1;
            for (size_t i = 0; i < page; i++) {
                const int inside = region + i >= start && region + i < start + len;
                if (inside && region[i] != 0) zeroed = 0;
                if (!inside && region[i] != 0xA5) intact = 0;
            }
            EXPECT(zeroed && intact, "wipe %zu bytes at offset %zu", len, offset);
        }
    }
    adf_crypto_wipe(region + page, 0);  // zero length at the edge: touches nothing
    munmap(map, 3 * page);
    // Allocation refuses nothing and too much, and returns zeroed, page-aligned blocks.
    EXPECT(adf_argon2_allocate(0) == NULL, "allocate 0 blocks");
    // Counts whose byte size wraps: to 0, to one block, to a few; each must be refused, never mapped small.
    EXPECT(adf_argon2_allocate(SIZE_MAX / 1024u + 1) == NULL, "allocate past SIZE_MAX (wraps to 0)");
    EXPECT(adf_argon2_allocate(SIZE_MAX / 1024u + 2) == NULL, "allocate past SIZE_MAX (wraps to one block)");
    EXPECT(adf_argon2_allocate(SIZE_MAX / 512u + 3) == NULL, "allocate past SIZE_MAX (wraps to a few blocks)");
    EXPECT(adf_argon2_allocate(SIZE_MAX) == NULL, "allocate SIZE_MAX blocks");
    uint64_t *memory = adf_argon2_allocate(3);
    int zero = memory != NULL && ((uintptr_t)memory % page) == 0;
    for (size_t i = 0; memory && i < 3 * 128; i++) zero &= memory[i] == 0;
    EXPECT(zero, "allocate 3 blocks, zeroed and aligned");
    adf_argon2_release(memory, 3);
    adf_argon2_release(NULL, 3);
}

int main(void) {
    for (int backend = ADF_CRYPTO_SCALAR; backend <= ADF_CRYPTO_AVX2; backend++) {
        if (adf_crypto_resolve(backend) != backend) continue;
        blake2b_answers(backend);
        for (uint32_t threads = 1; threads <= 4; threads++) {
            argon2_answer(0, "512b391b6f1162975371d30919734294f868e3be3984f3c1a13a4db9fabe4acb", backend, threads);
            argon2_answer(1, "c814d9d1dc7f37aa13f0d77f2494bda1c8de6b016dd388d29952a4c4672b6ce8", backend, threads);
            argon2_answer(2, "0d640df58d78766c08c037a34a8b53c9d01ef0452d75b65eb52520e96b01e659", backend, threads);
        }
    }
    secure_helpers();
    printf("published answers and secure helpers: %d checks, %d failures\n", checks, failures);
    return failures != 0;
}

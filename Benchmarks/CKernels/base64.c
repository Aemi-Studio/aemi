//
//  base64.c
//  Differential check (--check) and throughput (default) of CAemiKernels' Base64 block kernels against their scalar
//  references. The check allocates every input and output at its exact size, so under AddressSanitizer a load or store
//  outside the contract is an error; see Scripts/base64-kernels-check.sh.
//
#include "CAemiKernels.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static const char *alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static double now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec + (double)t.tv_nsec * 1e-9;
}

typedef struct {
    uint8_t table[64], lut[256];
    uint16_t tail;
} Alphabet;

/// `plus`/`slash` after A-Za-z0-9 (a ranged alphabet), or a shuffled alphabet when `shuffled` (tail 0).
static void make(Alphabet *a, char plus, char slash, int shuffled) {
    char symbols[65];
    memcpy(symbols, alphabet, 62);
    symbols[62] = plus;
    symbols[63] = slash;
    symbols[64] = 0;
    if (shuffled) {
        for (int i = 63; i > 0; i--) {
            const int j = rand() % (i + 1);
            const char t = symbols[i];
            symbols[i] = symbols[j];
            symbols[j] = t;
        }
    }
    memset(a->lut, 0xFF, sizeof a->lut);
    for (int i = 0; i < 64; i++) {
        a->table[i] = (uint8_t)symbols[i];
        a->lut[(uint8_t)symbols[i]] = (uint8_t)i;
    }
    a->tail = shuffled ? 0 : (uint16_t)((uint8_t)plus | (uint16_t)((uint8_t)slash << 8));
}

typedef size_t (*EncodeFn)(const uint8_t *, uint16_t, const uint8_t *, size_t, uint8_t *);
typedef size_t (*DecodeFn)(const uint8_t *, uint16_t, const uint8_t *, size_t, uint8_t *);

static long check_with(const char *name, EncodeFn encode, DecodeFn decode, long *checks_out) {
    (void)name;
    Alphabet set[4];
    make(&set[0], '+', '/', 0);
    make(&set[1], '-', '_', 0);
    make(&set[2], '*', ',', 0);
    make(&set[3], '+', '/', 1);
    long bad = 0, checks = 0;
    srand(7);
    for (int which = 0; which < 4; which++) {
        const Alphabet *a = &set[which];
        for (size_t n = 0; n < 700; n++) {
            for (int rep = 0; rep < 12; rep++) {
                uint8_t *in = malloc(n ? n : 1);
                for (size_t i = 0; i < n; i++) in[i] = (uint8_t)rand();
                // Encode: whatever each kernel consumed, the scalar reference gives the same symbols. Output is exactly
                // consumed / 3 * 4 bytes, so a store past it is an AddressSanitizer error; the size is learned from a dry
                // run on an oversized buffer, then the real call uses the exact one.
                uint8_t *probe = malloc(n / 3 * 4 + 64);
                const size_t consumed = encode(a->table, a->tail, in, n, probe);
                free(probe);
                uint8_t *fast = malloc(consumed / 3 * 4 + 1), *slow = malloc(consumed / 3 * 4 + 1);
                const size_t again = encode(a->table, a->tail, in, n, fast);
                const size_t reference = adf_b64_encode_blocks_scalar(a->table, in, consumed, slow);
                checks++;
                if (consumed % 3 != 0 || consumed > n || again != consumed || reference != consumed ||
                    memcmp(fast, slow, consumed / 3 * 4) != 0)
                    bad++;
                // Every backend encodes every whole group.
                if (consumed != n / 3 * 3) bad++;
                // Decode: random symbols, sometimes one random byte that is not a symbol.
                const size_t m = n / 4 * 4;
                uint8_t *text = malloc(m ? m : 1), *d1 = malloc(m / 4 * 3 + 1), *d2 = malloc(m / 4 * 3 + 1);
                for (size_t i = 0; i < m; i++) text[i] = a->table[rand() % 64];
                size_t at = m;
                if (m != 0 && rep % 2 == 1) {
                    at = (size_t)rand() % m;
                    do text[at] = (uint8_t)rand(); while (a->lut[text[at]] != 0xFF);
                }
                // Exact-size output: m / 4 * 3 bytes is the contract's room.
                uint8_t *e1 = malloc(m / 4 * 3 ? m / 4 * 3 : 1);
                const size_t r1 = decode(a->lut, a->tail, text, m, e1);
                const size_t r2 = adf_b64_decode_blocks_scalar(a->lut, text, m, d2);
                memcpy(d1, e1, r1 / 4 * 3);
                checks++;
                // Never past the scalar's stop, on a group edge, with the same bytes up to it...
                if (r1 % 4 != 0 || r1 != r2 || memcmp(d1, d2, r1 / 4 * 3) != 0) bad++;
                // ...never past a bad byte, and, for valid text, leaving less than one block (64 symbols) undone.
                if (at < m && r1 != at / 4 * 4) bad++;
                if (at >= m && r1 != m) bad++;
                free(in); free(fast); free(slow); free(text); free(d1); free(d2); free(e1);
            }
        }
    }
    *checks_out = checks;
    return bad;
}

typedef size_t (*LinesFn)(const uint8_t *, uint16_t, const uint8_t *, size_t, uint8_t *, size_t, size_t, size_t *);

/// Wrapped text against the scalar reference: widths around the vector steps, LF and CR LF, damaged lines and short outputs. The
/// input and output are exact-size allocations, so a stray access is an AddressSanitizer error.
static long check_lines(LinesFn lines, long *checks_out) {
    Alphabet a;
    make(&a, '+', '/', 0);
    const size_t widths[] = {0, 3, 4, 8, 12, 16, 20, 60, 64, 68, 76, 80, 128, 132};
    long bad = 0, checks = 0;
    srand(11);
    for (size_t w = 0; w < sizeof widths / sizeof widths[0]; w++) {
        const size_t width = widths[w];
        for (int rep = 0; rep < 400; rep++) {
            const size_t count = (size_t)(rand() % 12);
            const int crlf = rand() % 2;
            size_t len = 0;
            uint8_t *text = malloc(count * (width + 6) + 8);
            for (size_t l = 0; l < count; l++) {
                size_t symbols = width;
                if (rand() % 8 == 0 && symbols >= 4) symbols -= (size_t)(rand() % 4) + 1;  // a short line
                if (rand() % 16 == 0) symbols += 4;                                          // a long line
                for (size_t k = 0; k < symbols; k++) text[len++] = a.table[rand() % 64];
                if (crlf) text[len++] = 0x0D;
                if (rand() % 32 != 0) text[len++] = 0x0A;                                    // sometimes a lone CR
            }
            if (len > 0 && rand() % 4 == 0) text[(size_t)rand() % len] = (uint8_t)"=!- \x80"[rand() % 5];
            uint8_t *exact = malloc(len ? len : 1);
            memcpy(exact, text, len);
            const size_t cap = rand() % 3 == 0 ? (size_t)rand() % (len + 1) : len;
            uint8_t *o1 = malloc(cap ? cap : 1), *o2 = malloc(cap ? cap : 1);
            size_t w1 = 0, w2 = 0;
            const size_t c1 = lines(a.lut, a.tail, exact, len, o1, cap, width, &w1);
            const size_t c2 = adf_b64_decode_lines_scalar(a.lut, exact, len, o2, cap, width, &w2);
            checks++;
            if (c1 != c2 || w1 != w2 || w1 > cap || c1 > len || memcmp(o1, o2, w1) != 0) bad++;
            free(text); free(exact); free(o1); free(o2);
        }
    }
    *checks_out = checks;
    return bad;
}

/// Line-wrapped encoding against the scalar reference, exact-size buffers.
static long check_encode_lines(long *checks_out) {
    Alphabet a;
    make(&a, '+', '/', 0);
    const size_t widths[] = {0, 3, 4, 8, 12, 16, 20, 60, 64, 68, 76, 80, 128};
    long bad = 0, checks = 0;
    srand(13);
    for (size_t w = 0; w < sizeof widths / sizeof widths[0]; w++) {
        for (size_t n = 0; n < 400; n += 1 + (size_t)(rand() % 7)) {
            for (int crlf = 0; crlf < 2; crlf++) {
                uint8_t *in = malloc(n ? n : 1);
                for (size_t i = 0; i < n; i++) in[i] = (uint8_t)rand();
                const size_t full = n / 3 * 4 + (n / 3 + 1) * 2 + 8;
                const size_t cap = rand() % 3 == 0 ? (size_t)rand() % (full + 1) : full;
                uint8_t *o1 = malloc(cap ? cap : 1), *o2 = malloc(cap ? cap : 1);
                size_t w1 = 0, w2 = 0;
                const size_t c1 = adf_b64_encode_lines(a.table, a.tail, in, n, o1, cap, widths[w], crlf, &w1);
                const size_t c2 = adf_b64_encode_lines_scalar(a.table, in, n, o2, cap, widths[w], crlf, &w2);
                checks++;
                if (c1 != c2 || w1 != w2 || w1 > cap || c1 > n || memcmp(o1, o2, w1) != 0) bad++;
                free(in); free(o1); free(o2);
            }
        }
    }
    *checks_out = checks;
    return bad;
}

static int check(void) {
    const struct { const char *name; EncodeFn encode; DecodeFn decode; } backends[] = {
        {"dispatched", adf_b64_encode_blocks, adf_b64_decode_blocks},
        {"ssse3", adf_b64_encode_blocks_ssse3, adf_b64_decode_blocks_ssse3},
        {"avx2", adf_b64_encode_blocks_avx2, adf_b64_decode_blocks_avx2},
    };
    long total = 0;
    for (int i = 0; i < 3; i++) {
        long checks = 0;
        const long bad = check_with(backends[i].name, backends[i].encode, backends[i].decode, &checks);
        printf("base64 kernels, host %s, backend %s: %ld checks, %ld mismatches\n", adf_kernels_backend(), backends[i].name, checks, bad);
        total += bad;
    }
    long checks = 0;
    const long bad = check_lines(adf_b64_decode_lines, &checks);
    printf("base64 lines, host %s: %ld checks, %ld mismatches\n", adf_kernels_backend(), checks, bad);
    long encodeChecks = 0;
    const long encodeBad = check_encode_lines(&encodeChecks);
    printf("base64 encode lines, host %s: %ld checks, %ld mismatches\n", adf_kernels_backend(), encodeChecks, encodeBad);
    return total + bad + encodeBad != 0;
}

static double time_it(void (*body)(void *), void *ctx, int reps) {
    double best = 1e9;
    for (int round = 0; round < 9; round++) {
        const double t = now();
        for (int j = 0; j < reps; j++) body(ctx);
        const double each = (now() - t) / reps;
        if (each < best) best = each;
    }
    return best;
}

typedef struct { EncodeFn encode; DecodeFn decode; const Alphabet *a; const uint8_t *in, *text; uint8_t *out; size_t n, m; } Job;
static void run_encode(void *p) { Job *j = p; j->encode(j->a->table, j->a->tail, j->in, j->n, j->out); __asm__ volatile("" ::"r"(j->out) : "memory"); }
static void run_decode(void *p) { Job *j = p; j->decode(j->a->lut, j->a->tail, j->text, j->m, j->out); __asm__ volatile("" ::"r"(j->out) : "memory"); }

static size_t encode_scalar(const uint8_t *t, uint16_t tail, const uint8_t *in, size_t n, uint8_t *out) { (void)tail; return adf_b64_encode_blocks_scalar(t, in, n, out); }
static size_t decode_scalar(const uint8_t *l, uint16_t tail, const uint8_t *in, size_t n, uint8_t *out) { (void)tail; return adf_b64_decode_blocks_scalar(l, in, n, out); }

static void bench(void) {
    Alphabet a;
    make(&a, '+', '/', 0);
    const struct { const char *name; EncodeFn encode; DecodeFn decode; } backends[] = {
        {"scalar", encode_scalar, decode_scalar},
        {"dispatched", adf_b64_encode_blocks, adf_b64_decode_blocks},
        {"ssse3", adf_b64_encode_blocks_ssse3, adf_b64_decode_blocks_ssse3},
        {"avx2", adf_b64_encode_blocks_avx2, adf_b64_decode_blocks_avx2},
    };
    printf("host %s; GB/s of input (encode) and of decoded output (decode)\n", adf_kernels_backend());
    const size_t sizes[] = {64, 1024, 65536, 1 << 20};
    for (int k = 0; k < 4; k++) {
        const size_t n = sizes[k];
        uint8_t *in = malloc(n), *enc = malloc(n * 2), *out = malloc(n * 2);
        for (size_t i = 0; i < n; i++) in[i] = (uint8_t)rand();
        const size_t m = adf_b64_encode_blocks_scalar(a.table, in, n, enc) / 3 * 4;
        const int reps = (int)(1e8 / (double)n) + 1;
        printf("%8zu B ", n);
        for (int i = 0; i < 4; i++) {
            Job job = {backends[i].encode, backends[i].decode, &a, in, enc, out, n, m};
            const double e = time_it(run_encode, &job, reps), d = time_it(run_decode, &job, reps);
            printf(" | %s enc %5.2f dec %5.2f", backends[i].name, (double)n / e / 1e9, (double)(m / 4 * 3) / d / 1e9);
        }
        printf("\n");
        free(in); free(enc); free(out);
    }
}

int main(int argc, char **argv) {
    if (argc > 1 && strcmp(argv[1], "--check") == 0) return check();
    bench();
    return 0;
}

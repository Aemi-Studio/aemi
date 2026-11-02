//
//  percent.c
//  Differential check (--check) and throughput (default) of CAemiKernels' percent-coding kernels against their scalar
//  references, on exact-size allocations (AddressSanitizer sees any stray access). See Scripts/codec-kernels-check.sh.
//
#include "CAemiKernels.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static double now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec + (double)t.tv_nsec * 1e-9;
}

/// Nibble tables for `member` (as `AemiKernels.ByteSet` builds them); 0 when the set needs more than eight rows.
static int make_set(int (*member)(int), uint8_t lo[16], uint8_t hi[16]) {
    uint16_t rows[16] = {0}, patterns[8];
    int count = 0;
    memset(lo, 0, 16);
    memset(hi, 0, 16);
    for (int b = 0; b < 256; b++) if (member(b)) rows[b >> 4] |= (uint16_t)(1u << (b & 15));
    for (int upper = 0; upper < 16; upper++) {
        if (!rows[upper]) continue;
        int bit = -1;
        for (int k = 0; k < count; k++) if (patterns[k] == rows[upper]) bit = k;
        if (bit < 0) {
            if (count == 8) return 0;
            patterns[count] = rows[upper];
            bit = count++;
        }
        hi[upper] = (uint8_t)(1u << bit);
        for (int lower = 0; lower < 16; lower++) if (rows[upper] & (1u << lower)) lo[lower] |= (uint8_t)(1u << bit);
    }
    return 1;
}

static int reserved(int b) {
    const int unreserved = (b >= 'A' && b <= 'Z') || (b >= 'a' && b <= 'z') || (b >= '0' && b <= '9') || b == '-' || b == '.' ||
                           b == '_' || b == '~';
    return !unreserved;
}
static int slash_and_space(int b) { return b == '/' || b == ' ' || b >= 0x80; }

static int check(void) {
    uint8_t lo[2][16], hi[2][16];
    if (!make_set(reserved, lo[0], hi[0]) || !make_set(slash_and_space, lo[1], hi[1])) return 2;
    long bad = 0, checks = 0;
    srand(17);
    for (int s = 0; s < 2; s++) {
        for (size_t n = 0; n < 500; n++) {
            for (int rep = 0; rep < 8; rep++) {
                uint8_t *in = malloc(n ? n : 1);
                const int density = rep % 4;  // 0: random bytes, 1: mostly plain, 2: plain, 3: dense
                for (size_t i = 0; i < n; i++) {
                    in[i] = density == 0 ? (uint8_t)rand()
                          : density == 3 ? (uint8_t)(rand() % 3 == 0 ? 'a' : ' ')
                          : (uint8_t)('a' + rand() % 26);
                    if (density == 1 && rand() % 40 == 0) in[i] = '/';
                }
                const size_t count = adf_count_in_set(in, n, lo[s], hi[s]);
                checks++;
                if (count != adf_count_in_set_scalar(in, n, lo[s], hi[s])) bad++;
                const size_t cap = n + 2 * count;
                uint8_t *o1 = malloc(cap ? cap : 1), *o2 = malloc(cap ? cap : 1);
                const size_t w1 = adf_percent_encode(in, n, lo[s], hi[s], o1, cap);
                const size_t w2 = adf_percent_encode_scalar(in, n, lo[s], hi[s], o2, cap);
                checks++;
                if (w1 != cap || w2 != cap || memcmp(o1, o2, cap) != 0) bad++;
                // One byte short: both refuse, and neither writes past the smaller capacity.
                if (cap > 0) {
                    uint8_t *small = malloc(cap - 1 ? cap - 1 : 1);
                    checks++;
                    if (adf_percent_encode(in, n, lo[s], hi[s], small, cap - 1) != SIZE_MAX) bad++;
                    free(small);
                }
                // Decode what was encoded (sometimes damaged), as a form and not.
                for (int plus = 0; plus < 2; plus++) {
                    uint8_t *text = malloc(cap ? cap : 1);
                    memcpy(text, o1, cap);
                    if (cap && rep % 3 == 2) text[(size_t)rand() % cap] = (uint8_t)"%G+z"[rand() % 4];
                    uint8_t *d1 = malloc(cap ? cap : 1), *d2 = malloc(cap ? cap : 1);
                    size_t b1 = 0, b2 = 0;
                    const size_t r1 = adf_percent_decode(text, cap, d1, plus, &b1);
                    const size_t r2 = adf_percent_decode_scalar(text, cap, d2, plus, &b2);
                    checks++;
                    if (r1 != r2 || (r1 == SIZE_MAX ? b1 != b2 : memcmp(d1, d2, r1) != 0)) bad++;
                    if (s == 0 && rep % 3 != 2 && !plus && (r1 != n || memcmp(d1, in, n) != 0)) bad++;  // set 1 leaves `%` unescaped
                    free(text); free(d1); free(d2);
                }
                free(in); free(o1); free(o2);
            }
        }
    }
    printf("percent kernels, host %s: %ld checks, %ld mismatches\n", adf_kernels_backend(), checks, bad);
    return bad != 0;
}

static void bench(void) {
    uint8_t lo[16], hi[16];
    make_set(reserved, lo, hi);
    const size_t n = 1 << 20;
    printf("host %s; 1 MiB, GB/s of input\n", adf_kernels_backend());
    for (int density = 0; density < 3; density++) {
        uint8_t *in = malloc(n), *out = malloc(3 * n), *back = malloc(3 * n);
        for (size_t i = 0; i < n; i++) in[i] = (uint8_t)('a' + (int)(i % 26));
        if (density == 1) for (size_t i = 7; i < n; i += 8) in[i] = ' ';
        if (density == 2) for (size_t i = 0; i < n; i += 2) in[i] = '/';
        const size_t cap = n + 2 * adf_count_in_set_scalar(in, n, lo, hi);
        double best[4] = {1e9, 1e9, 1e9, 1e9};
        size_t bad = 0;
        for (int round = 0; round < 7; round++) {
            double t = now();
            adf_percent_encode_scalar(in, n, lo, hi, out, cap);
            t = now() - t; if (t < best[0]) best[0] = t;
            t = now();
            adf_percent_encode(in, n, lo, hi, out, cap);
            t = now() - t; if (t < best[1]) best[1] = t;
            t = now();
            adf_percent_decode_scalar(out, cap, back, 0, &bad);
            t = now() - t; if (t < best[2]) best[2] = t;
            t = now();
            adf_percent_decode(out, cap, back, 0, &bad);
            t = now() - t; if (t < best[3]) best[3] = t;
        }
        printf("%s  encode scalar %5.2f simd %5.2f | decode scalar %5.2f simd %5.2f\n",
               density == 0 ? "no escapes " : density == 1 ? "1 in 8     " : "1 in 2     ", (double)n / best[0] / 1e9,
               (double)n / best[1] / 1e9, (double)cap / best[2] / 1e9, (double)cap / best[3] / 1e9);
        free(in); free(out); free(back);
    }
}

int main(int argc, char **argv) {
    if (argc > 1 && strcmp(argv[1], "--check") == 0) return check();
    bench();
    return 0;
}

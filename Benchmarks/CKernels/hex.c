//
//  hex.c
//  Differential check (--check) and throughput (default) of CAemiKernels' hex kernels against their scalar references, on
//  exact-size allocations so AddressSanitizer sees any access outside the contract. See Scripts/codec-kernels-check.sh.
//
#include "CAemiKernels.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

typedef void (*EncodeFn)(const uint8_t *, size_t, uint8_t *, int);
typedef size_t (*DecodeFn)(const uint8_t *, size_t, uint8_t *);

static double fmin_(double a, double b) { return a < b ? a : b; }

static double now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec + (double)t.tv_nsec * 1e-9;
}

static long check_with(EncodeFn encode, DecodeFn decode, long *checks) {
    long bad = 0;
    srand(5);
    for (size_t n = 0; n < 600; n++) {
        for (int rep = 0; rep < 12; rep++) {
            const int upper = rep % 2;
            uint8_t *in = malloc(n ? n : 1);
            for (size_t i = 0; i < n; i++) in[i] = (uint8_t)rand();
            uint8_t *fast = malloc(2 * n + 1), *slow = malloc(2 * n + 1);
            encode(in, n, fast, upper);
            adf_hex_encode_scalar(in, n, slow, upper);
            ++*checks;
            if (memcmp(fast, slow, 2 * n) != 0) bad++;
            // Decode: the digits (mixed case), sometimes one damaged byte, sometimes an odd length.
            size_t m = 2 * n - (rep % 5 == 4 && n > 0 ? 1 : 0);
            uint8_t *text = malloc(m ? m : 1);
            for (size_t i = 0; i < m; i++) text[i] = (rand() % 3 == 0 && slow[i] >= 'a') ? (uint8_t)(slow[i] - 32) : slow[i];
            size_t at = m;
            if (m && rep % 3 == 1) {
                at = (size_t)rand() % m;
                const uint8_t junk[] = {'g', 'G', '/', ':', '@', '`', 0x80, 0xFF, 0, ' ', 'x'};
                text[at] = junk[rand() % (int)sizeof junk];
            }
            uint8_t *d1 = malloc(m / 2 ? m / 2 : 1), *d2 = malloc(m / 2 ? m / 2 : 1);
            const size_t r1 = decode(text, m, d1), r2 = adf_hex_decode_scalar(text, m, d2);
            ++*checks;
            if (r1 != r2 || memcmp(d1, d2, r1 / 2) != 0) bad++;
            if (at >= m && r1 != m / 2 * 2) bad++;
            if (at < m && r1 != at / 2 * 2) bad++;
            if (at >= m && memcmp(d1, in, m / 2) != 0) bad++;
            free(in); free(fast); free(slow); free(text); free(d1); free(d2);
        }
    }
    return bad;
}

static int check(void) {
    const struct { const char *name; EncodeFn encode; DecodeFn decode; } backends[] = {
        {"dispatched", adf_hex_encode, adf_hex_decode},
        {"ssse3", adf_hex_encode_ssse3, adf_hex_decode_ssse3},
        {"avx2", adf_hex_encode_avx2, adf_hex_decode_avx2},
    };
    long total = 0;
    for (int i = 0; i < 3; i++) {
        long checks = 0;
        const long bad = check_with(backends[i].encode, backends[i].decode, &checks);
        printf("hex kernels, host %s, backend %s: %ld checks, %ld mismatches\n", adf_kernels_backend(), backends[i].name, checks, bad);
        total += bad;
    }
    return total != 0;
}

static void bench(void) {
    const size_t sizes[] = {64, 1024, 65536, 1 << 20};
    printf("host %s; GB/s of bytes (encode input, decode output)\n", adf_kernels_backend());
    for (int k = 0; k < 4; k++) {
        const size_t n = sizes[k];
        uint8_t *in = malloc(n), *text = malloc(2 * n), *out = malloc(n);
        for (size_t i = 0; i < n; i++) in[i] = (uint8_t)rand();
        adf_hex_encode_scalar(in, n, text, 0);
        const int reps = (int)(1e8 / (double)n) + 1;
        double best[4] = {1e9, 1e9, 1e9, 1e9};
        for (int round = 0; round < 7; round++) {
            double t = now();
            for (int j = 0; j < reps; j++) { adf_hex_encode_scalar(in, n, text, 0); __asm__ volatile("" ::"r"(text) : "memory"); }
            best[0] = fmin_(best[0], (now() - t) / reps);
            t = now();
            for (int j = 0; j < reps; j++) { adf_hex_encode(in, n, text, 0); __asm__ volatile("" ::"r"(text) : "memory"); }
            best[1] = fmin_(best[1], (now() - t) / reps);
            t = now();
            for (int j = 0; j < reps; j++) { adf_hex_decode_scalar(text, 2 * n, out); __asm__ volatile("" ::"r"(out) : "memory"); }
            best[2] = fmin_(best[2], (now() - t) / reps);
            t = now();
            for (int j = 0; j < reps; j++) { adf_hex_decode(text, 2 * n, out); __asm__ volatile("" ::"r"(out) : "memory"); }
            best[3] = fmin_(best[3], (now() - t) / reps);
        }
        printf("%8zu B  encode scalar %6.2f simd %6.2f | decode scalar %6.2f simd %6.2f\n", n, (double)n / best[0] / 1e9,
               (double)n / best[1] / 1e9, (double)n / best[2] / 1e9, (double)n / best[3] / 1e9);
        free(in); free(text); free(out);
    }
}

int main(int argc, char **argv) {
    if (argc > 1 && strcmp(argv[1], "--check") == 0) return check();
    bench();
    return 0;
}

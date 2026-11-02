//
//  find.c
//  Differential check (--check) and throughput (default) of CAemiKernels' byte-string search against the plain reference, on
//  exact-size allocations (AddressSanitizer sees any stray read), including the adversarial inputs that make it give up.
//
#define _DARWIN_C_SOURCE
#define _GNU_SOURCE
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

/// Checks one search: an exact answer equals the reference; a give-up rules out exactly the starts before `resume`.
typedef size_t (*FindFn)(const uint8_t *, size_t, const uint8_t *, size_t, size_t *);
static const FindFn finders[] = {adf_find, adf_find_sse2, adf_find_avx2};

/// Checks one search on every backend: an exact answer equals the reference; a give-up rules out exactly the starts before `resume`.
static int agrees(const uint8_t *hay, size_t hlen, const uint8_t *needle, size_t nlen) {
    const size_t expected = adf_find_scalar(hay, hlen, needle, nlen);
    for (int f = 0; f < 3; f++) {
        size_t resume = 0;
        const size_t found = finders[f](hay, hlen, needle, nlen, &resume);
        if (found != ADF_FIND_GAVE_UP) {
            if (found != expected) return 0;
            continue;
        }
        // Gave up: no match starts before `resume`, and `resume` is a real start.
        if (resume + nlen > hlen) return 0;
        if (expected != SIZE_MAX && expected < resume) return 0;
    }
    return 1;
}

static int check(void) {
    long bad = 0, checks = 0, gaveUp = 0;
    srand(23);
    for (size_t hlen = 0; hlen < 400; hlen++) {
        for (int rep = 0; rep < 20; rep++) {
            const int alphabet = 2 + rep % 4;  // small alphabets make candidates frequent
            uint8_t *hay = malloc(hlen ? hlen : 1);
            for (size_t i = 0; i < hlen; i++) hay[i] = (uint8_t)('a' + rand() % alphabet);
            const size_t nlen = (size_t)(rand() % 40);
            uint8_t *needle = malloc(nlen ? nlen : 1);
            if (hlen >= nlen && nlen > 0 && rep % 2 == 0) {
                const size_t at = (size_t)rand() % (hlen - nlen + 1);
                memcpy(needle, hay + at, nlen);  // a needle that occurs
            } else {
                for (size_t i = 0; i < nlen; i++) needle[i] = (uint8_t)('a' + rand() % alphabet);
            }
            checks++;
            if (!agrees(hay, hlen, needle, nlen)) bad++;
            free(hay);
            free(needle);
        }
    }
    // Adversarial: "aaaa...a" for "aaa...aba...a" (every start a candidate, each compared far); and a match at the very end.
    for (size_t hlen = 1000; hlen <= 64000; hlen *= 4) {
        for (size_t nlen = 3; nlen <= 2000; nlen = nlen * 3 + 1) {
            if (nlen > hlen) continue;
            uint8_t *hay = malloc(hlen), *needle = malloc(nlen);
            memset(hay, 'a', hlen);
            memset(needle, 'a', nlen);
            needle[nlen / 2] = 'b';
            checks++;
            size_t resume = 0;
            const size_t found = adf_find(hay, hlen, needle, nlen, &resume);
            if (found == ADF_FIND_GAVE_UP) gaveUp++;
            if (!agrees(hay, hlen, needle, nlen)) bad++;
            memcpy(hay + hlen - nlen, needle, nlen);
            checks++;
            if (!agrees(hay, hlen, needle, nlen)) bad++;
            free(hay);
            free(needle);
        }
    }
    // Where the budget runs out, a match must not be skipped: the needle placed at every start around the first give-up.
    for (size_t nlen = 9; nlen <= 1500; nlen = nlen * 2 + 1) {
        const size_t hlen = 40000;
        uint8_t *hay = malloc(hlen), *needle = malloc(nlen);
        memset(hay, 'a', hlen);
        memset(needle, 'a', nlen);
        needle[nlen / 2] = 'b';
        size_t first = 0;
        if (adf_find(hay, hlen, needle, nlen, &first) != ADF_FIND_GAVE_UP) {  // a short needle stays inside the budget
            free(hay);
            free(needle);
            continue;
        }
        const size_t from = first > 2 * nlen ? first - 2 * nlen : 0;
        for (size_t at = from; at <= first + 2 * nlen && at + nlen <= hlen; at++) {
            memset(hay, 'a', hlen);
            memcpy(hay + at, needle, nlen);
            checks++;
            if (!agrees(hay, hlen, needle, nlen)) bad++;
        }
        free(hay);
        free(needle);
    }
    printf("find kernels, host %s: %ld checks, %ld mismatches (%ld adversarial searches gave up, as designed)\n", adf_kernels_backend(),
           checks, bad, gaveUp);
    return bad != 0 || gaveUp == 0;
}

static void bench(void) {
    const size_t n = 1 << 20;
    uint8_t *hay = malloc(n);
    for (size_t i = 0; i < n; i++) hay[i] = (uint8_t)("abcdefghijklmnopqrstuvwxyz \n"[i % 28]);
    const char *needles[] = {"zz", "needle!", "a much longer needle that is not there at all"};
    printf("host %s; 1 MiB of text, no match, GB/s\n", adf_kernels_backend());
    for (int k = 0; k < 3; k++) {
        const size_t nlen = strlen(needles[k]);
        double best[3] = {1e9, 1e9, 1e9};
        for (int round = 0; round < 7; round++) {
            size_t resume;
            double t = now();
            if (adf_find(hay, n, (const uint8_t *)needles[k], nlen, &resume) != SIZE_MAX) printf("!");
            t = now() - t; if (t < best[0]) best[0] = t;
            t = now();
            if (adf_find_scalar(hay, n, (const uint8_t *)needles[k], nlen) != SIZE_MAX) printf("!");
            t = now() - t; if (t < best[1]) best[1] = t;
            t = now();
            if (memmem(hay, n, needles[k], nlen) != NULL) printf("!");
            t = now() - t; if (t < best[2]) best[2] = t;
        }
        printf("needle of %2zu  simd %6.2f | reference %5.2f | libc memmem %5.2f\n", nlen, (double)n / best[0] / 1e9,
               (double)n / best[1] / 1e9, (double)n / best[2] / 1e9);
    }
    free(hay);
}

int main(int argc, char **argv) {
    if (argc > 1 && strcmp(argv[1], "--check") == 0) return check();
    bench();
    return 0;
}

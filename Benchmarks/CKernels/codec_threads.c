//
//  codec_threads.c
//  Every CAemiKernels kernel (the codecs, search, scanners, folding, UTF-8 and UTF-16, CRC-32C, bit counts, Hamming, sets) called
//  from many threads at once, from the first call on (when each dispatcher resolves the CPU's
//  features), under ThreadSanitizer: no data race, and every thread's answers equal the scalar reference. Run by
//  Scripts/kernels-check.sh with -fsanitize=thread.
//
#include "CAemiKernels.h"

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum { THREADS = 16, ROUNDS = 200 };

static int failed[THREADS];

#if defined(__APPLE__)
// macOS has no pthread barriers: a counter and a condition.
typedef struct {
    pthread_mutex_t lock;
    pthread_cond_t ready;
    int waiting;
} Barrier;
static Barrier barrier = {PTHREAD_MUTEX_INITIALIZER, PTHREAD_COND_INITIALIZER, 0};
static void wait_for_all(void) {
    pthread_mutex_lock(&barrier.lock);
    if (++barrier.waiting == THREADS) {
        pthread_cond_broadcast(&barrier.ready);
    } else {
        while (barrier.waiting < THREADS) pthread_cond_wait(&barrier.ready, &barrier.lock);
    }
    pthread_mutex_unlock(&barrier.lock);
}
#else
static pthread_barrier_t real_barrier;
static void wait_for_all(void) { pthread_barrier_wait(&real_barrier); }
#endif

static void *work(void *argument) {
    const int id = (int)(intptr_t)argument;
    uint8_t table[64], lut[256];
    const char *symbols = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    memset(lut, 0xFF, sizeof lut);
    for (int i = 0; i < 64; i++) {
        table[i] = (uint8_t)symbols[i];
        lut[(uint8_t)symbols[i]] = (uint8_t)i;
    }
    const uint16_t tail = (uint16_t)('+' | '/' << 8);
    uint8_t in[600], a[1200], b[1200], c[1200], d[1200];
    wait_for_all();
    for (int round = 0; round < ROUNDS; round++) {
        const size_t n = (size_t)(round * 7 + id * 13) % 600;
        for (size_t i = 0; i < n; i++) in[i] = (uint8_t)(i * 31 + (size_t)round + (size_t)id);
        // Base64 both ways.
        adf_b64_encode_blocks(table, tail, in, n, a);
        adf_b64_encode_blocks_scalar(table, in, n, b);
        if (memcmp(a, b, n / 3 * 4) != 0) failed[id] = 1;
        if (adf_b64_decode_blocks(lut, tail, a, n / 3 * 4, c) != n / 3 * 4 || memcmp(c, in, n / 3 * 3) != 0) failed[id] = 1;
        size_t written = 0;
        adf_b64_encode_lines(table, tail, in, n, d, sizeof d, 76, round & 1, &written);
        // Hex both ways.
        adf_hex_encode(in, n, a, round & 1);
        if (adf_hex_decode(a, 2 * n, c) != 2 * n || memcmp(c, in, n) != 0) failed[id] = 1;
        // Search.
        size_t resume = 0;
        if (n > 8 && adf_find(in, n, in + n - 8, 8, &resume) != adf_find_scalar(in, n, in + n - 8, 8)) failed[id] = 1;
        // Percent decode of plain text.
        size_t bad = 0;
        memset(a, 'q', n);
        if (adf_percent_decode(a, n, c, 1, &bad) != n) failed[id] = 1;
        // The scanners, folding, validation, checksums and counts, each against its reference.
        if (adf_index_of_string_stop(in, n, '"', '\\') != adf_index_of_string_stop_scalar(in, n, '"', '\\')) failed[id] = 1;
        if (adf_index_of_nonascii(in, n) != adf_index_of_nonascii_scalar(in, n)) failed[id] = 1;
        if (adf_index_of_any5(in, n, 1, 2, 3, 4, 5) != adf_index_of_any5_scalar(in, n, 1, 2, 3, 4, 5)) failed[id] = 1;
        if (adf_index_of_control_or_any5(in, n, 1, 2, 3, 4, 5) != adf_index_of_control_or_any5_scalar(in, n, 1, 2, 3, 4, 5)) failed[id] = 1;
        if (adf_first_disallowed_text(in, n, 0x20, 1) != adf_first_disallowed_text_scalar(in, n, 0x20, 1)) failed[id] = 1;
        if (adf_first_invalid_utf8(in, n) != adf_first_invalid_utf8_scalar(in, n)) failed[id] = 1;
        adf_fold_ascii(a, in, n);
        adf_fold_ascii_scalar(b, in, n);
        if (memcmp(a, b, n) != 0) failed[id] = 1;
        if (adf_crc32c_update(7, in, n) != adf_crc32c_update_scalar(7, in, n)) failed[id] = 1;
        if (adf_bit_count(in, n) != adf_bit_count_scalar(in, n)) failed[id] = 1;
        if (adf_hamming_distance(in, a, n) != adf_hamming_distance_scalar(in, a, n)) failed[id] = 1;
        if (adf_utf16le_ascii_prefix(in, n / 2, a) != adf_utf16le_ascii_prefix_scalar(in, n / 2, b)) failed[id] = 1;
        const uint8_t lo[16] = {1, 2}, hi[16] = {3, 3, 3};
        if (adf_index_of_set(in, n, lo, hi) != adf_index_of_set_scalar(in, n, lo, hi)) failed[id] = 1;
        uint8_t table[64] = {0};
        table[3] = 1;
        table[16 + 2] = 1;
        table[32 + 5] = 1;
        table[48 + 6] = 1;
        if (adf_pair_set_find(table, in, n, 0) != adf_pair_set_find_scalar(table, in, n, 0)) failed[id] = 1;
    }
    return NULL;
}

int main(void) {
#if !defined(__APPLE__)
    pthread_barrier_init(&real_barrier, NULL, THREADS);
#endif
    pthread_t threads[THREADS];
    for (int i = 0; i < THREADS; i++) pthread_create(&threads[i], NULL, work, (void *)(intptr_t)i);
    int failures = 0;
    for (int i = 0; i < THREADS; i++) {
        pthread_join(threads[i], NULL);
        failures += failed[i];
    }
    printf("threads (host %s): %d threads x %d rounds, %d failing\n", adf_kernels_backend(), THREADS, ROUNDS, failures);
    return failures != 0;
}

// A dudect-style timing attack on the kernels (Reparaz, Balasch, Verbauwhede, "Dude, is my code constant time?", 2017):
// each kernel runs on a fixed secret and on random secrets, the two classes interleaved at random, each measurement a
// batch of calls; Welch's t-test compares the timings, after cropping the slowest tail (interrupts, preemption). |t| above
// 4.5 is a leak. A deliberately leaky comparison (an early exit) is the positive control: the method must see it.
// Exit 0 when every constant-time kernel stays below the threshold and the control is caught.
#include "CAemiArgon2.h"
#include "../../Sources/CAemiArgon2/adf_argon2_internal.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static uint64_t rng = 0x5eed;
static uint64_t next_random(void) {
    rng += 0x9e3779b97f4a7c15u;
    uint64_t z = rng;
    z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9u;
    z = (z ^ (z >> 27)) * 0x94d049bb133111ebu;
    return z ^ (z >> 31);
}

static uint64_t now(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

typedef void (*kernel_fn)(uint8_t *secret, int iterations);

static volatile int sink;

/// Welch's t over the measurements of each class below the `keep` quantile of all.
static double welch_t(const double *time, const int *klass, int count, double keep) {
    double *sorted = malloc(sizeof(double) * (size_t)count);
    memcpy(sorted, time, sizeof(double) * (size_t)count);
    int compare(const void *a, const void *b);
    qsort(sorted, (size_t)count, sizeof(double), compare);
    const double limit = sorted[(int)(keep * (count - 1))];
    free(sorted);
    double n[2] = {0, 0}, mean[2] = {0, 0}, m2[2] = {0, 0};
    for (int i = 0; i < count; i++) {
        if (time[i] > limit) continue;
        const int c = klass[i];
        n[c] += 1;
        const double delta = time[i] - mean[c];
        mean[c] += delta / n[c];
        m2[c] += delta * (time[i] - mean[c]);
    }
    const double v0 = m2[0] / (n[0] - 1), v1 = m2[1] / (n[1] - 1);
    return (mean[0] - mean[1]) / sqrt(v0 / n[0] + v1 / n[1]);
}

int compare(const void *a, const void *b) {
    const double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}

/// The largest |t| over three crops, as dudect reports.
static double attack(kernel_fn kernel, size_t secret_length, int measurements, int iterations) {
    uint8_t *secrets = malloc(secret_length * (size_t)measurements);
    int *klass = malloc(sizeof(int) * (size_t)measurements);
    double *time = malloc(sizeof(double) * (size_t)measurements);
    for (int i = 0; i < measurements; i++) {
        klass[i] = (int)(next_random() & 1);
        for (size_t b = 0; b < secret_length; b++) {
            secrets[(size_t)i * secret_length + b] = klass[i] ? (uint8_t)next_random() : 0;
        }
    }
    for (int warm = 0; warm < 1000; warm++) kernel(secrets, 1);
    for (int i = 0; i < measurements; i++) {
        const uint64_t start = now();
        kernel(secrets + (size_t)i * secret_length, iterations);
        time[i] = (double)(now() - start);
    }
    double worst = 0;
    const double crops[] = {0.5, 0.9, 0.99};
    for (int c = 0; c < 3; c++) {
        const double t = fabs(welch_t(time, klass, measurements, crops[c]));
        if (t > worst) worst = t;
    }
    free(secrets);
    free(klass);
    free(time);
    return worst;
}

// The kernels under attack. The secret is 32 bytes for comparisons, two blocks for G, a block and a state for F.
static uint8_t reference[32];
static void equal_kernel(uint8_t *secret, int iterations) {
    for (int i = 0; i < iterations; i++) sink += adf_crypto_equal(secret, reference, 32);
}
static void leaky_kernel(uint8_t *secret, int iterations) {
    for (int i = 0; i < iterations; i++) {
        int equal = 1;
        for (int b = 0; b < 32; b++) if (secret[b] != reference[b]) { equal = 0; break; }
        sink += equal;
    }
}
static int block_backend;
static void block_kernel(uint8_t *secret, int iterations) {
    uint64_t prev[128], ref[128], out[128];
    memcpy(prev, secret, 1024);
    memcpy(ref, secret + 1024, 1024);
    for (int i = 0; i < iterations; i++) adf_argon2_block(out, prev, ref, i & 1, block_backend);
    sink += (int)out[0];
}
static void blake_kernel(uint8_t *secret, int iterations) {
    uint64_t state[8], block[16];
    memcpy(state, secret, 64);
    memcpy(block, secret + 64, 128);
    for (int i = 0; i < iterations; i++) adf_blake2b_compress(state, block, 128, 0, i & 1, block_backend);
    sink += (int)state[0];
}
static uint32_t fill_type;
static void fill_kernel(uint8_t *secret, int iterations) {
    enum { lanes = 1, lane_length = 64 };
    static uint64_t *memory;
    if (!memory) memory = adf_argon2_allocate(lanes * lane_length);
    for (int i = 0; i < iterations; i++) {
        memcpy(memory, secret, 2048);
        adf_argon2_fill_t fill = {memory, lanes, lane_length, 1, fill_type, 1, ADF_CRYPTO_FASTEST};
        adf_argon2_fill(&fill);
    }
    sink += (int)memory[0];
}

int main(void) {
    int failures = 0;
    const double threshold = 4.5;
    double t = attack(leaky_kernel, 32, 200000, 64);
    printf("  control, an early-exit comparison: |t| = %6.1f (must be over %.1f)\n", t, threshold);
    failures += t <= threshold;
    t = attack(equal_kernel, 32, 200000, 64);
    printf("  adf_crypto_equal:                  |t| = %6.1f\n", t);
    failures += t > threshold;
    for (int backend = ADF_CRYPTO_SCALAR; backend <= ADF_CRYPTO_AVX2; backend++) {
        if (adf_crypto_resolve(backend) != backend) continue;
        block_backend = backend;
        t = attack(block_kernel, 2048, 60000, 8);
        printf("  G, %-10s                     |t| = %6.1f\n", adf_crypto_backend_name(backend), t);
        failures += t > threshold;
        t = attack(blake_kernel, 192, 100000, 32);
        printf("  BLAKE2b F, %-10s             |t| = %6.1f\n", adf_crypto_backend_name(backend), t);
        failures += t > threshold;
    }
    fill_type = 1;
    t = attack(fill_kernel, 2048, 20000, 1);
    printf("  fill, Argon2i (data-independent):  |t| = %6.1f\n", t);
    failures += t > threshold;
    fill_type = 2;
    t = attack(fill_kernel, 2048, 20000, 1);
    printf("  fill, Argon2id (informational):    |t| = %6.1f\n", t);
    fill_type = 0;
    t = attack(fill_kernel, 2048, 20000, 1);
    printf("  fill, Argon2d (informational):     |t| = %6.1f\n", t);
    printf(failures == 0 ? "ok\n" : "LEAK, or the control was not caught\n");
    return failures == 0 ? 0 : 1;
}

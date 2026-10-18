// Benchmark and differential check for CAemiKernels' fold_ascii and index_of_nonascii.
//
// Run through `scripts/bench-c-kernels.sh`, which compiles every variant in its own translation unit
// with the flags under test. The rules this harness keeps, each answering a mistake already made once:
//
// - Variants are reached through function pointers in separate translation units: no inlining, so
//   no dead-store elimination of a kernel whose output the harness "does not use".
// - Outputs are consumed: fold results are checksummed after every sample, scan results summed
//   inside the timed loop, and the totals printed.
// - `--check` compares every variant with the scalar reference over exact-size allocations, meant
//   for an AddressSanitizer build, so an out-of-bounds read fails instead of passing silently.
// - Samples are interleaved across variants in a shuffled order each round, so drift from thermal
//   state or background load spreads over all variants rather than biasing whichever ran last.
// - The reported figure is the median with its p10–p90 spread, never the best sample.

#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "CAemiKernels.h"

typedef void (*fold_fn)(uint8_t *dst, const uint8_t *src, size_t len);
typedef size_t (*scan_fn)(const uint8_t *buf, size_t len);

void prev_fold_ascii_neon(uint8_t *dst, const uint8_t *src, size_t len);
void ref_fold_ascii_Os(uint8_t *dst, const uint8_t *src, size_t len);
void ref_fold_ascii_O2(uint8_t *dst, const uint8_t *src, size_t len);
void ref_fold_ascii_O2_novec(uint8_t *dst, const uint8_t *src, size_t len);
size_t ref_index_of_nonascii_Os(const uint8_t *buf, size_t len);
size_t ref_index_of_nonascii_O2(const uint8_t *buf, size_t len);
size_t ref_index_of_nonascii_O2_novec(const uint8_t *buf, size_t len);

typedef struct {
    const char *name;
    fold_fn fn;
} fold_variant;

typedef struct {
    const char *name;
    scan_fn fn;
} scan_variant;

static const fold_variant fold_variants[] = {
    {"shipped NEON (-Os)", adf_fold_ascii_neon},
    {"shipped dispatcher (-Os)", adf_fold_ascii},
    {"previous NEON, 3e64286^ (-Os)", prev_fold_ascii_neon},
    {"scalar -Os (as shipped)", ref_fold_ascii_Os},
    {"scalar -O2", ref_fold_ascii_O2},
    {"scalar -O2, no vectorize", ref_fold_ascii_O2_novec},
};

static const scan_variant scan_variants[] = {
    {"shipped NEON (-Os)", adf_index_of_nonascii_neon},
    {"shipped dispatcher (-Os)", adf_index_of_nonascii},
    {"scalar -Os (as shipped)", ref_index_of_nonascii_Os},
    {"scalar -O2", ref_index_of_nonascii_O2},
    {"scalar -O2, no vectorize", ref_index_of_nonascii_O2_novec},
};

#define FOLD_COUNT (sizeof fold_variants / sizeof fold_variants[0])
#define SCAN_COUNT (sizeof scan_variants / sizeof scan_variants[0])
#define ROUNDS 31
#define MAX_VARIANTS 8

static uint64_t rng_state = 0x9E3779B97F4A7C15u;

static uint64_t next_random(void) {
    rng_state ^= rng_state << 13;
    rng_state ^= rng_state >> 7;
    rng_state ^= rng_state << 17;
    return rng_state;
}

static uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

/// Printable ASCII, about half letters, mixed case: the input fold_ascii exists for.
static void fill_mixed_ascii(uint8_t *buf, size_t len) {
    for (size_t i = 0; i < len; ++i) {
        uint64_t r = next_random();
        if (r & 1) {
            buf[i] = (uint8_t)(((r >> 8) & 1 ? 'A' : 'a') + (r >> 16) % 26);
        } else {
            buf[i] = (uint8_t)(0x20 + (r >> 16) % 95);
        }
    }
}

static int compare_doubles(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}

static void shuffle(size_t *order, size_t count) {
    for (size_t i = count; i > 1; --i) {
        size_t j = (size_t)(next_random() % i);
        size_t t = order[i - 1];
        order[i - 1] = order[j];
        order[j] = t;
    }
}

// MARK: - Differential check

static int check_fold(void) {
    int failures = 0;
    for (size_t len = 0; len <= 300 && failures < 10; ++len) {
        for (size_t offset = 0; offset < 64 && failures < 10; ++offset) {
            uint8_t *src_block = malloc(offset + len + 1);
            uint8_t *expected = malloc(len + 1);
            uint8_t *actual_block = malloc(offset + len + 1);
            if (!src_block || !expected || !actual_block) return 1;
            uint8_t *src = src_block + offset;  // ends exactly at the allocation's end
            uint8_t *actual = actual_block + offset;
            for (size_t i = 0; i < len; ++i) src[i] = (uint8_t)next_random();
            ref_fold_ascii_O2_novec(expected, src, len);
            for (size_t v = 0; v < FOLD_COUNT; ++v) {
                memset(actual, 0xAB, len);
                fold_variants[v].fn(actual, src, len);
                if (len && memcmp(actual, expected, len) != 0) {
                    printf("MISMATCH fold %s len %zu offset %zu\n", fold_variants[v].name, len, offset);
                    ++failures;
                }
            }
            free(src_block);
            free(expected);
            free(actual_block);
        }
    }
    return failures;
}

static int check_scan(void) {
    int failures = 0;
    for (size_t len = 0; len <= 300 && failures < 10; ++len) {
        for (size_t offset = 0; offset < 64 && failures < 10; offset += 7) {
            uint8_t *block = malloc(offset + len + 1);
            if (!block) return 1;
            uint8_t *buf = block + offset;
            // Every position of the first non-ASCII byte, then none at all.
            for (size_t hit = 0; hit <= len && failures < 10; ++hit) {
                for (size_t i = 0; i < len; ++i) buf[i] = (uint8_t)(next_random() & 0x7F);
                if (hit < len) buf[hit] = (uint8_t)(0x80 | (next_random() & 0x7F));
                size_t expected = ref_index_of_nonascii_O2_novec(buf, len);
                for (size_t v = 0; v < SCAN_COUNT; ++v) {
                    size_t got = scan_variants[v].fn(buf, len);
                    if (got != expected) {
                        printf("MISMATCH scan %s len %zu hit %zu: %zu != %zu\n", scan_variants[v].name, len,
                               hit, got, expected);
                        ++failures;
                    }
                }
            }
            free(block);
        }
    }
    return failures;
}

// MARK: - Timing

static uint64_t fold_sink = 0;
static size_t scan_sink = 0;

static uint64_t checksum(const uint8_t *buf, size_t len) {
    uint64_t sum = 0;
    for (size_t i = 0; i < len; ++i) sum = sum * 31 + buf[i];
    return sum;
}

static double time_fold(fold_fn fn, uint8_t *dst, const uint8_t *src, size_t len, size_t iterations) {
    uint64_t start = now_ns();
    for (size_t k = 0; k < iterations; ++k) fn(dst, src, len);
    uint64_t elapsed = now_ns() - start;
    fold_sink ^= checksum(dst, len < 4096 ? len : 4096) + dst[len - 1];
    return (double)elapsed / (double)iterations;
}

static double time_scan(scan_fn fn, const uint8_t *buf, size_t len, size_t iterations) {
    size_t sum = 0;
    uint64_t start = now_ns();
    for (size_t k = 0; k < iterations; ++k) sum += fn(buf, len);
    uint64_t elapsed = now_ns() - start;
    scan_sink += sum;
    return (double)elapsed / (double)iterations;
}

/// Iterations for one sample of at least 2 ms with the slowest variant, so timer resolution and
/// call overhead stay negligible.
static size_t calibrate(double slowest_ns_per_call) {
    double target = 2.0e6;
    size_t n = (size_t)(target / slowest_ns_per_call) + 1;
    return n < 3 ? 3 : n;
}

static void report(const char *family, size_t len, const char *const *names, size_t count,
                   double samples[][ROUNDS], size_t baseline) {
    double medians[MAX_VARIANTS];
    printf("\n%s, %zu bytes (median of %d interleaved samples; GB/s of input)\n", family, len, ROUNDS);
    printf("  %-32s %9s %19s %10s\n", "variant", "median", "p10 .. p90", "vs base");
    for (size_t v = 0; v < count; ++v) {
        double gbps[ROUNDS];
        for (int r = 0; r < ROUNDS; ++r) gbps[r] = (double)len / samples[v][r];
        qsort(gbps, ROUNDS, sizeof(double), compare_doubles);
        medians[v] = gbps[ROUNDS / 2];
        printf("  %-32s %9.2f %8.2f .. %8.2f", names[v], gbps[ROUNDS / 2], gbps[ROUNDS / 10],
               gbps[ROUNDS - 1 - ROUNDS / 10]);
        printf("\n");
    }
    for (size_t v = 0; v < count; ++v) {
        printf("  ratio %-26s %6.2fx of \"%s\"\n", names[v], medians[v] / medians[baseline], names[baseline]);
    }
}

static void bench_fold(size_t len) {
    uint8_t *src = NULL, *dst = NULL;
    if (posix_memalign((void **)&src, 64, len) || posix_memalign((void **)&dst, 64, len)) exit(1);
    fill_mixed_ascii(src, len);
    double slowest = 0;
    for (size_t v = 0; v < FOLD_COUNT; ++v) {
        double t = time_fold(fold_variants[v].fn, dst, src, len, 3);
        if (t > slowest) slowest = t;
    }
    size_t iterations = calibrate(slowest);
    double samples[MAX_VARIANTS][ROUNDS];
    size_t order[MAX_VARIANTS];
    for (size_t v = 0; v < FOLD_COUNT; ++v) order[v] = v;
    for (int r = 0; r < ROUNDS; ++r) {
        shuffle(order, FOLD_COUNT);
        for (size_t i = 0; i < FOLD_COUNT; ++i) {
            size_t v = order[i];
            samples[v][r] = time_fold(fold_variants[v].fn, dst, src, len, iterations);
        }
    }
    const char *names[MAX_VARIANTS];
    for (size_t v = 0; v < FOLD_COUNT; ++v) names[v] = fold_variants[v].name;
    report("fold_ascii", len, names, FOLD_COUNT, samples, 3);
    free(src);
    free(dst);
}

static void bench_scan(size_t len) {
    uint8_t *buf = NULL;
    if (posix_memalign((void **)&buf, 64, len)) exit(1);
    fill_mixed_ascii(buf, len);  // all ASCII: every variant scans the whole buffer
    double slowest = 0;
    for (size_t v = 0; v < SCAN_COUNT; ++v) {
        double t = time_scan(scan_variants[v].fn, buf, len, 3);
        if (t > slowest) slowest = t;
    }
    size_t iterations = calibrate(slowest);
    double samples[MAX_VARIANTS][ROUNDS];
    size_t order[MAX_VARIANTS];
    for (size_t v = 0; v < SCAN_COUNT; ++v) order[v] = v;
    for (int r = 0; r < ROUNDS; ++r) {
        shuffle(order, SCAN_COUNT);
        for (size_t i = 0; i < SCAN_COUNT; ++i) {
            size_t v = order[i];
            samples[v][r] = time_scan(scan_variants[v].fn, buf, len, iterations);
        }
    }
    const char *names[MAX_VARIANTS];
    for (size_t v = 0; v < SCAN_COUNT; ++v) names[v] = scan_variants[v].name;
    report("index_of_nonascii (no match: full scan)", len, names, SCAN_COUNT, samples, 2);
    free(buf);
}

int main(int argc, char **argv) {
    if (argc > 1 && strcmp(argv[1], "--check") == 0) {
        int failures = check_fold() + check_scan();
        printf("differential check: %d mismatches (%zu fold and %zu scan variants)\n", failures, FOLD_COUNT,
               SCAN_COUNT);
        return failures != 0;
    }
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    double load[3] = {0, 0, 0};
    getloadavg(load, 3);
    printf("backend %s; load average %.2f %.2f %.2f; %s\n", adf_kernels_backend(), load[0], load[1], load[2],
           __clang_version__);
    const size_t sizes[] = {64, 1024, 64 * 1024, 1024 * 1024, 8 * 1024 * 1024};
    for (size_t s = 0; s < sizeof sizes / sizeof sizes[0]; ++s) bench_fold(sizes[s]);
    for (size_t s = 0; s < sizeof sizes / sizeof sizes[0]; ++s) bench_scan(sizes[s]);
    printf("\nsinks %llu %zu\n", (unsigned long long)fold_sink, scan_sink);
    return 0;
}

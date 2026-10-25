// Benchmark and differential check of CAemiKernels' byte scanners on inputs of about one line.
//
// Run through `scripts/bench-c-kernels.sh --small` (timing) or `--check` (correctness). The harness.c
// rules apply: every variant sits behind a function pointer in its own translation unit, outputs are
// consumed, samples are interleaved in a shuffled order, and the figure is a median with its p10-p90
// spread. What this file adds:
//
// - The unit is nanoseconds per call, not GB/s: at 80 bytes a call is a handful of nanoseconds, and
//   the fixed cost of the call is what is being measured.
// - "before" is the previous revision of adf_scan.c (BASE_REF in the script), renamed `prev_*`, so the
//   comparison is against what shipped and not against a model of it.
// - Two scenarios per length. "no hit" scans the whole input. "random hit" plants the stop byte at a
//   random position (or none) in each of 256 different buffers and cycles through them, so the branch
//   predictor cannot learn one position, as it could with a fixed one.
// - The differential check compares every variant with the scalar reference over every length from 0 to
//   300, 10 alignments, every position of the first hit and of a second hit after it, on exact-size
//   allocations (meant for an AddressSanitizer build), with clean ASCII and with random bytes behind.

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "CAemiKernels.h"

typedef size_t (*scan_fn)(const uint8_t *buf, size_t len);
typedef void (*plant_fn)(uint8_t *buf, size_t position);

uint64_t small_next_random(void);
void small_shuffle(size_t *order, size_t count);
int small_compare_doubles(const void *a, const void *b);

// MARK: - The kernels under test, with the needles Markdown's inline scanner would use

#define MD_NEEDLES '*', '_', '`', '[', '\\'

#define DEFINE_ADAPTERS(NAME, CALL_NOW, CALL_PREV, CALL_REF)                                      \
    static size_t now_##NAME(const uint8_t *buf, size_t len) { return CALL_NOW; }                 \
    static size_t prev_##NAME(const uint8_t *buf, size_t len) { return CALL_PREV; }               \
    static size_t ref_##NAME(const uint8_t *buf, size_t len) { return CALL_REF; }

size_t prev_index_of_any5(const uint8_t *, size_t, uint8_t, uint8_t, uint8_t, uint8_t, uint8_t);
size_t prev_index_of_control_or_any5(const uint8_t *, size_t, uint8_t, uint8_t, uint8_t, uint8_t, uint8_t);
size_t prev_index_of_nonascii(const uint8_t *, size_t);
size_t prev_index_of_string_stop(const uint8_t *, size_t, uint8_t, uint8_t);
size_t prev_first_disallowed_text(const uint8_t *, size_t, uint8_t, int);

DEFINE_ADAPTERS(any5, adf_index_of_any5(buf, len, MD_NEEDLES),
                prev_index_of_any5(buf, len, MD_NEEDLES),
                adf_index_of_any5_scalar(buf, len, MD_NEEDLES))
DEFINE_ADAPTERS(control_or_any5, adf_index_of_control_or_any5(buf, len, MD_NEEDLES),
                prev_index_of_control_or_any5(buf, len, MD_NEEDLES),
                adf_index_of_control_or_any5_scalar(buf, len, MD_NEEDLES))
DEFINE_ADAPTERS(nonascii, adf_index_of_nonascii(buf, len), prev_index_of_nonascii(buf, len),
                adf_index_of_nonascii_scalar(buf, len))
DEFINE_ADAPTERS(string_stop, adf_index_of_string_stop(buf, len, '"', '\\'),
                prev_index_of_string_stop(buf, len, '"', '\\'),
                adf_index_of_string_stop_scalar(buf, len, '"', '\\'))
DEFINE_ADAPTERS(disallowed, adf_first_disallowed_text(buf, len, 0x20, 1),
                prev_first_disallowed_text(buf, len, 0x20, 1),
                adf_first_disallowed_text_scalar(buf, len, 0x20, 1))

static void plant_markdown(uint8_t *buf, size_t position) { buf[position] = "*_`[\\"[position % 5]; }
static void plant_nonascii(uint8_t *buf, size_t position) { buf[position] = (uint8_t)(0x80 | (position & 0x7F)); }
static void plant_quote(uint8_t *buf, size_t position) { buf[position] = position & 1 ? '"' : '\\'; }
static void plant_control(uint8_t *buf, size_t position) { buf[position] = position & 1 ? 0x1B : 0x7F; }

typedef struct {
    const char *name;
    scan_fn now, prev, ref;
    plant_fn plant;
} kernel;

static const kernel kernels[] = {
    {"index_of_any5", now_any5, prev_any5, ref_any5, plant_markdown},
    {"index_of_control_or_any5", now_control_or_any5, prev_control_or_any5, ref_control_or_any5, plant_markdown},
    {"index_of_nonascii", now_nonascii, prev_nonascii, ref_nonascii, plant_nonascii},
    {"index_of_string_stop", now_string_stop, prev_string_stop, ref_string_stop, plant_quote},
    {"first_disallowed_text", now_disallowed, prev_disallowed, ref_disallowed, plant_control},
};
#define KERNEL_COUNT (sizeof kernels / sizeof kernels[0])

/// Letters, digits and spaces: no byte any kernel above stops on.
static void fill_clean(uint8_t *buf, size_t len) {
    static const char alphabet[] = "abcdefghijklmnopqrstuvwxyz ABCDEFGHIJKLMNOPQRSTUVWXYZ 0123456789 ,.;:";
    for (size_t i = 0; i < len; ++i) buf[i] = (uint8_t)alphabet[small_next_random() % (sizeof alphabet - 1)];
}

// MARK: - Differential check

static int check_parameters(void);

int check_small(void) {
    int failures = check_parameters();
    for (size_t k = 0; k < KERNEL_COUNT && failures < 10; ++k) {
        for (size_t len = 0; len <= 300 && failures < 10; ++len) {
            for (size_t offset = 0; offset < 64 && failures < 10; offset += 7) {
                uint8_t *block = malloc(offset + len > 0 ? offset + len : 1);  // exact: no slack byte after the input
                if (!block) return 1;
                uint8_t *buf = block + offset;  // ends exactly at the allocation's end
                for (int noisy = 0; noisy < 2; ++noisy) {
                    for (size_t hit = 0; hit <= len && failures < 10; ++hit) {
                        if (noisy) {
                            for (size_t i = 0; i < len; ++i) buf[i] = (uint8_t)small_next_random();
                        } else {
                            fill_clean(buf, len);
                        }
                        if (hit < len) {
                            kernels[k].plant(buf, hit);
                            // A second stop byte after the first: the first one must still win.
                            if (hit + 1 < len) kernels[k].plant(buf, hit + 1 + small_next_random() % (len - hit - 1));
                        }
                        size_t expected = kernels[k].ref(buf, len);
                        scan_fn variants[2] = {kernels[k].now, kernels[k].prev};
                        const char *labels[2] = {"now", "prev"};
                        for (int v = 0; v < 2; ++v) {
                            size_t got = variants[v](buf, len);
                            if (got != expected) {
                                printf("MISMATCH %s %s len %zu offset %zu hit %zu noisy %d: %zu != %zu\n",
                                       kernels[k].name, labels[v], len, offset, hit, noisy, got, expected);
                                ++failures;
                            }
                        }
                    }
                }
                free(block);
            }
        }
    }
    return failures;
}

/// The kernels that take parameters, with random parameters: every `min_allowed` (a value above 0x80 must
/// still let bytes of 0x80 and over through), needles of any value, repeated or zero. Found a real defect
/// in the first version of adf_neon_scan.h's disallowed-text classifier, which the fixed parameters
/// above did not reach (AemiKernelsTests did).
static int check_parameters(void) {
    static const char special[12] = {'a', 'b', '*', '_', '`', ' ', '\\', '"', '\t', 0x7F, (char)0x80, (char)0xC3};
    int failures = 0;
    uint8_t *block = NULL;
    for (int round = 0; round < 6000 && failures < 10; ++round) {
        size_t len = (size_t)(small_next_random() % 131);
        block = malloc(len > 0 ? len : 1);
        if (!block) return 1;
        for (size_t i = 0; i < len; ++i) {
            uint64_t r = small_next_random();
            block[i] = (r & 3) == 0 ? (uint8_t)(r >> 8) : (uint8_t)special[(r >> 8) % 12];
        }
        uint8_t n[5], min_allowed = (uint8_t)small_next_random();
        for (int i = 0; i < 5; ++i) n[i] = (small_next_random() & 1) ? n[0] : (uint8_t)small_next_random();
        int allow_tab = (int)(small_next_random() & 1);
        if (adf_first_disallowed_text(block, len, min_allowed, allow_tab) !=
            adf_first_disallowed_text_scalar(block, len, min_allowed, allow_tab)) {
            printf("MISMATCH first_disallowed_text len %zu min %u tab %d\n", len, min_allowed, allow_tab);
            ++failures;
        }
        if (adf_index_of_any5(block, len, n[0], n[1], n[2], n[3], n[4]) !=
            adf_index_of_any5_scalar(block, len, n[0], n[1], n[2], n[3], n[4])) {
            printf("MISMATCH index_of_any5 len %zu needles %u %u %u %u %u\n", len, n[0], n[1], n[2], n[3], n[4]);
            ++failures;
        }
        if (adf_index_of_control_or_any5(block, len, n[0], n[1], n[2], n[3], n[4]) !=
            adf_index_of_control_or_any5_scalar(block, len, n[0], n[1], n[2], n[3], n[4])) {
            printf("MISMATCH index_of_control_or_any5 len %zu needles %u %u\n", len, n[0], n[1]);
            ++failures;
        }
        if (adf_index_of_string_stop(block, len, n[0], n[1]) != adf_index_of_string_stop_scalar(block, len, n[0], n[1])) {
            printf("MISMATCH index_of_string_stop len %zu quote %u escape %u\n", len, n[0], n[1]);
            ++failures;
        }
        free(block);
    }
    return failures;
}

// MARK: - Timing

#define ROUNDS 31
#define BUFFERS 256

static size_t small_sink = 0;

static uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

/// Mean nanoseconds for one call over `iterations` calls, cycling through `BUFFERS` inputs of `len`.
static double time_calls(scan_fn fn, uint8_t *const *inputs, size_t len, size_t iterations) {
    size_t sum = 0;
    uint64_t start = now_ns();
    for (size_t i = 0; i < iterations; ++i) sum += fn(inputs[i & (BUFFERS - 1)], len);
    uint64_t elapsed = now_ns() - start;
    small_sink += sum;
    return (double)elapsed / (double)iterations;
}

static void bench_one(const kernel *kernel, size_t len, int random_hit) {
    uint8_t *inputs[BUFFERS];
    for (size_t b = 0; b < BUFFERS; ++b) {
        if (posix_memalign((void **)&inputs[b], 64, len + 64)) exit(1);
        fill_clean(inputs[b], len);
        if (random_hit) {
            // One byte in 8 has no hit at all, as a line of plain text has none.
            size_t position = (size_t)(small_next_random() % (len + len / 8));
            if (position < len) kernel->plant(inputs[b], position);
        }
    }
    scan_fn fns[2] = {kernel->prev, kernel->now};
    const char *names[2] = {"before (afc1be3)", "after"};
    size_t iterations = 200000;
    double samples[2][ROUNDS];
    for (int r = 0; r < ROUNDS; ++r) {
        size_t order[2] = {0, 1};
        small_shuffle(order, 2);
        for (size_t i = 0; i < 2; ++i) samples[order[i]][r] = time_calls(fns[order[i]], inputs, len, iterations);
    }
    double median[2];
    printf("%-26s %4zu bytes %-10s", kernel->name, len, random_hit ? "random hit" : "no hit");
    for (int v = 0; v < 2; ++v) {
        qsort(samples[v], ROUNDS, sizeof(double), small_compare_doubles);
        median[v] = samples[v][ROUNDS / 2];
        printf("  %s %6.2f ns (%5.2f .. %5.2f)", names[v], median[v], samples[v][ROUNDS / 10],
               samples[v][ROUNDS - 1 - ROUNDS / 10]);
    }
    printf("  %.2fx\n", median[0] / median[1]);
    for (size_t b = 0; b < BUFFERS; ++b) free(inputs[b]);
}

void bench_small(void) {
    const size_t lengths[] = {16, 33, 64, 79, 80, 128, 255};
    for (size_t k = 0; k < KERNEL_COUNT; ++k) {
        for (size_t l = 0; l < sizeof lengths / sizeof lengths[0]; ++l) {
            bench_one(&kernels[k], lengths[l], 0);
            bench_one(&kernels[k], lengths[l], 1);
        }
        printf("\n");
    }
    printf("sink %zu\n", small_sink);
}

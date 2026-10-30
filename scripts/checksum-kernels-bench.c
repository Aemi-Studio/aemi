// Throughput of the ADR 0020 kernels at the optimisation a release build ships (-Os), median of nine runs.
#include "CAemiKernels.h"

#include <stdio.h>
#include <stdlib.h>
#include <time.h>

static double now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec + (double)t.tv_nsec / 1e9;
}

static int compare(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : x > y;
}

#define MEASURE(label, bytes, body)                                                             \
    do {                                                                                        \
        double runs[9];                                                                         \
        for (int r = 0; r < 9; r++) { double s = now(); body; runs[r] = now() - s; }            \
        qsort(runs, 9, sizeof runs[0], compare);                                                \
        printf("  %-40s %7.2f GB/s\n", label, (double)(bytes) / runs[4] / 1e9);                 \
    } while (0)

int main(void) {
    const size_t size = 64u << 20;
    uint8_t *data = malloc(size), *ascii = malloc(size / 2);
    if (!data || !ascii) return 2;
    for (size_t i = 0; i < size; i++) data[i] = (uint8_t)(i * 2654435761u >> 13);
    volatile uint64_t sink = 0;
    printf("%s\n", adf_kernels_backend());
    MEASURE("crc32c, 64 MiB", size, sink += adf_crc32c_update(~0u, data, size));
    MEASURE("crc32c, 4 KiB blocks", size, for (size_t b = 0; b < size; b += 4096) sink += adf_crc32c_update(~0u, data + b, 4064));
    MEASURE("crc32c scalar (table), 64 MiB", size, sink += adf_crc32c_update_scalar(~0u, data, size));
    MEASURE("bit count, 64 MiB", size, sink += adf_bit_count(data, size));
    MEASURE("bit count scalar, 64 MiB", size, sink += adf_bit_count_scalar(data, size));
    for (size_t i = 0; i < size; i += 2) { data[i] = (uint8_t)(0x20 + (i % 90)); data[i + 1] = 0; }
    MEASURE("utf16le ascii prefix, 32 Mi units", size, sink += adf_utf16le_ascii_prefix(data, size / 2, ascii));
    MEASURE("utf16le ascii prefix scalar", size, sink += adf_utf16le_ascii_prefix_scalar(data, size / 2, ascii));
    free(data); free(ascii);
    return sink == 42 ? 3 : 0;
}

// Differential check of the ADR 0020 kernels: every backend this CPU takes against the scalar reference, over random
// lengths and offsets, under ASan and UBSan (checksum-kernels-check.sh builds it for the host and for x86-64).
#include "CAemiKernels.h"

#include <stdio.h>
#include <stdlib.h>

static uint64_t state = 0x9E3779B97F4A7C15u;
static uint8_t next_byte(void) {
    state = state * 6364136223846793005u + 1442695040888963407u;
    return (uint8_t)(state >> 33);
}

int main(void) {
    enum { size = 70000 };
    uint8_t *data = malloc(size);
    uint8_t *ascii = malloc(size);
    uint8_t *expected = malloc(size);
    if (!data || !ascii || !expected) return 2;
    for (size_t i = 0; i < size; i++) data[i] = next_byte();
    size_t checks = 0, failures = 0;
    for (size_t trial = 0; trial < 20000; trial++) {
        size_t offset = next_byte() & 15;
        size_t length = (trial < 4000) ? trial % 4000 : ((size_t)next_byte() << 8 | next_byte()) % (size - 16);
        const uint8_t *p = data + offset;
        uint32_t seed = (uint32_t)trial * 2654435761u;
        failures += adf_crc32c_update(seed, p, length) != adf_crc32c_update_scalar(seed, p, length);
        failures += adf_bit_count(p, length) != adf_bit_count_scalar(p, length);
        // Mostly ASCII text with an occasional wide unit, so the prefix ends at varied places.
        uint8_t *text = data + 16;
        size_t units = length / 2;
        for (size_t u = 0; u < units && u < 4000; u++) { text[2 * u] = (uint8_t)(0x20 + (u % 90)); text[2 * u + 1] = 0; }
        // The blocker is a unit with a high byte, or one from 0x80 to 0xFF (high byte zero), which only a test of the
        // low byte's top bit catches.
        if (units > 0 && (trial & 3)) {
            size_t at = next_byte() % (units < 4000 ? units : 4000);
            if (trial & 4) text[2 * at + 1] = 1; else text[2 * at] = (uint8_t)(0x80 | next_byte());
        }
        size_t a = adf_utf16le_ascii_prefix(text, units < 4000 ? units : 4000, ascii);
        size_t b = adf_utf16le_ascii_prefix_scalar(text, units < 4000 ? units : 4000, expected);
        failures += a != b;
        for (size_t i = 0; i < a && i < b; i++) failures += ascii[i] != expected[i];
        for (size_t i = 0; i < size; i++) if (i >= 16 && i < 16 + 8000) data[i] = next_byte();
        checks += 3;
    }
    printf("  %s: %zu checks, %zu failures (crc32c+pmull: %d)\n", adf_kernels_backend(), checks, failures, adf_kernels_has_crc32_pmull());
    free(data); free(ascii); free(expected);
    return failures == 0 ? 0 : 1;
}

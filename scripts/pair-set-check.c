// Checks the Teddy kernel's SIMD path against its scalar reference on random tables and haystacks, for every start offset, and that no
// byte past the end of the buffer is read (the bytes after it are poisoned to look like a pair).
// Built for x86_64 and run under Rosetta by scripts/pair-set-check.sh, to test the SSSE3 path from an arm64 machine. Correctness only:
// Rosetta timings say nothing about native Intel or AMD speed.
#include "../Sources/CAemiKernels/include/CAemiKernels.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint64_t state = 0x9E3779B97F4A7C15ull;
static uint64_t next(void) { state += 0x9E3779B97F4A7C15ull; uint64_t z = state; z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull; z = (z ^ (z >> 27)) * 0x94D049BB133111EBull; return z ^ (z >> 31); }

int main(void) {
    const char alphabet[] = "abcdefgxyz ABC_\n12";
    size_t checks = 0;
    size_t sizes[] = {0, 1, 2, 15, 16, 17, 18, 33, 63, 64, 65, 66, 127, 128, 129, 200, 513, 1000};
    for (size_t s = 0; s < sizeof sizes / sizeof sizes[0]; s++) {
        size_t size = sizes[s];
        for (int round = 0; round < 40; round++) {
            uint8_t table[ADF_PAIR_SET_TABLE_BYTES] = {0};
            int pairs = 1 + round % 16;
            for (int k = 0; k < pairs; k++) {
                uint8_t a = (uint8_t)alphabet[next() % 18], b = (uint8_t)alphabet[next() % 18], bucket = (uint8_t)(1u << (k % 8));
                table[a & 15] |= bucket; table[16 + (a >> 4)] |= bucket; table[32 + (b & 15)] |= bucket; table[48 + (b >> 4)] |= bucket;
            }
            uint8_t *buffer = malloc(size + 80);
            for (size_t i = 0; i < size; i++) buffer[i] = (uint8_t)alphabet[next() % 18];
            memset(buffer + size, 'b', 80);                 // poison past the end
            if (size > 0) buffer[size - 1] = 'a';
            for (size_t from = 0; from <= size; from++) {
                size_t simd = adf_pair_set_find(table, buffer, size, from), scalar = adf_pair_set_find_scalar(table, buffer, size, from);
                if (simd != scalar) { printf("MISMATCH size %zu from %zu round %d: simd %zu scalar %zu\n", size, from, round, simd, scalar); return 1; }
                if (simd != SIZE_MAX && (simd < from || simd + 1 >= size)) { printf("OUT OF RANGE %zu (size %zu)\n", simd, size); return 1; }
                checks++;
            }
            // The batch call: every candidate once, in order, for several capacities; never past `cap`, with a guard band after it.
            size_t caps[] = {1, 5, 16, 17, 64, 256};
            for (size_t c = 0; c < sizeof caps / sizeof caps[0]; c++) {
                size_t cap = caps[c], expected[2048], expected_count = 0;
                for (size_t from = 0; from < size;) {
                    size_t r = adf_pair_set_find_scalar(table, buffer, size, from);
                    if (r == SIZE_MAX) break;
                    expected[expected_count++] = r; from = r + 1;
                }
                size_t out[256 + 8], collected[2048], collected_count = 0, resume = 0, from = 0;
                for (int guard = 0; from < size && guard < 5000; guard++) {
                    for (size_t g = 0; g < cap + 8 && g < 264; g++) out[g] = 0xDEADBEEF;
                    size_t k = adf_pair_set_candidates(table, buffer, size, from, out, cap, &resume);
                    if (k > cap) { printf("BATCH wrote %zu > cap %zu\n", k, cap); return 1; }
                    for (size_t g = cap; g < cap + 8 && g < 264; g++) if (out[g] != 0xDEADBEEF) { printf("BATCH wrote past cap %zu\n", cap); return 1; }
                    for (size_t g = 0; g < k; g++) collected[collected_count++] = out[g];
                    if (!(resume > from || resume >= size)) { printf("BATCH no progress at %zu (cap %zu)\n", from, cap); return 1; }
                    from = resume;
                }
                if (collected_count != expected_count || memcmp(collected, expected, collected_count * sizeof(size_t)) != 0) {
                    printf("BATCH MISMATCH size %zu cap %zu round %d: %zu vs %zu candidates\n", size, cap, round, collected_count, expected_count);
                    return 1;
                }
                checks++;
            }
            free(buffer);
        }
    }
    // Dense case: every position but the last is a candidate, so the output buffer fills in every call.
    {
        uint8_t table[ADF_PAIR_SET_TABLE_BYTES] = {0};
        const uint8_t ab[2] = {'a', 'b'};
        for (int x = 0; x < 2; x++) for (int y = 0; y < 2; y++) {
            uint8_t bucket = (uint8_t)(1u << (2 * x + y));
            table[ab[x] & 15] |= bucket; table[16 + (ab[x] >> 4)] |= bucket; table[32 + (ab[y] & 15)] |= bucket; table[48 + (ab[y] >> 4)] |= bucket;
        }
        for (size_t size = 2; size <= 600; size += (size < 140 ? 1 : 37)) {
            uint8_t *buffer = malloc(size); for (size_t i = 0; i < size; i++) buffer[i] = (next() & 1) ? 'a' : 'b';
            size_t caps[] = {1, 2, 15, 16, 17, 63, 64, 65, 100, 256};
            for (size_t c = 0; c < sizeof caps / sizeof caps[0]; c++) {
                size_t cap = caps[c], out[256 + 8], total = 0, resume = 0, from = 0, expected_next = 0;
                for (int guard = 0; from < size && guard < 5000; guard++) {
                    for (size_t g = 0; g < cap + 8 && g < 264; g++) out[g] = 0xDEADBEEF;
                    size_t k = adf_pair_set_candidates(table, buffer, size, from, out, cap, &resume);
                    if (k > cap) { printf("DENSE wrote %zu > cap %zu\n", k, cap); return 1; }
                    for (size_t g = cap; g < cap + 8 && g < 264; g++) if (out[g] != 0xDEADBEEF) { printf("DENSE wrote past cap %zu (size %zu)\n", cap, size); return 1; }
                    for (size_t g = 0; g < k; g++) { if (out[g] != expected_next++) { printf("DENSE wrong candidate\n"); return 1; } total++; }
                    if (!(resume > from || resume >= size)) { printf("DENSE no progress\n"); return 1; }
                    from = resume;
                }
                if (total != size - 1) { printf("DENSE %zu candidates, wanted %zu (size %zu cap %zu)\n", total, size - 1, size, cap); return 1; }
                checks++;
            }
            free(buffer);
        }
    }
    printf("ok: %zu checks, SIMD == scalar (find and batch), none out of range, batch never past its capacity\n", checks);
    return 0;
}

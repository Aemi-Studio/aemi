// The Argon2 kernels against their scalar references, for every backend this CPU runs: G on random blocks with and
// without the xor, BLAKE2b's F on random blocks, and whole fills (every variant, lanes 1 to 5, threads 1 to 4) compared
// block for block with a scalar fill on one thread. Built with ASan and UBSan by check.sh. Exit 0 when all agree.
#include "CAemiArgon2.h"
#include "../../Sources/CAemiArgon2/adf_argon2_internal.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint64_t state = 0x9106;
static uint64_t next_random(void) {
    state += 0x9e3779b97f4a7c15u;
    uint64_t z = state;
    z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9u;
    z = (z ^ (z >> 27)) * 0x94d049bb133111ebu;
    return z ^ (z >> 31);
}

static int failures = 0, checks = 0;

static void check_blocks(int backend, adf_argon2_block_fn direct) {
    uint64_t prev[128], ref[128], start[128], expected[128], actual[128];
    for (int round = 0; round < 2000; round++) {
        for (int i = 0; i < 128; i++) { prev[i] = next_random(); ref[i] = next_random(); start[i] = next_random(); }
        for (int with_xor = 0; with_xor < 2; with_xor++) {
            memcpy(expected, start, sizeof start);
            memcpy(actual, start, sizeof start);
            adf_argon2_block_scalar(expected, prev, ref, with_xor);
            if (direct) direct(actual, prev, ref, with_xor); else adf_argon2_block(actual, prev, ref, with_xor, backend);
            checks++;
            if (memcmp(expected, actual, sizeof actual) != 0) failures++;
        }
    }
}

static void check_blake2b(int backend) {
    for (int round = 0; round < 2000; round++) {
        uint64_t block[16], expected[8], actual[8];
        for (int i = 0; i < 16; i++) block[i] = next_random();
        for (int i = 0; i < 8; i++) expected[i] = actual[i] = next_random();
        const uint64_t low = next_random(), high = next_random() & 1;
        const int last = (int)(next_random() & 1);
        adf_blake2b_compress(expected, block, low, high, last, ADF_CRYPTO_SCALAR);
        adf_blake2b_compress(actual, block, low, high, last, backend);
        checks++;
        if (memcmp(expected, actual, sizeof actual) != 0) failures++;
    }
}

static void check_fills(int backend) {
    for (uint32_t type = 0; type < 3; type++) {
        for (uint32_t lanes = 1; lanes <= 5; lanes++) {
            const uint32_t lane_length = 4u * (2u + (uint32_t)(next_random() % 40));
            const size_t blocks = (size_t)lanes * lane_length;
            uint64_t *reference = adf_argon2_allocate(blocks), *memory = adf_argon2_allocate(blocks);
            for (uint32_t threads = 1; threads <= 4; threads++) {
                for (size_t i = 0; i < blocks * 128; i++) reference[i] = 0;
                for (uint32_t lane = 0; lane < lanes; lane++)
                    for (int i = 0; i < 256; i++) reference[(size_t)lane * lane_length * 128 + (size_t)i] = next_random();
                memcpy(memory, reference, blocks * 1024);
                adf_argon2_fill_t scalar = {reference, lanes, lane_length, 3, type, 1, ADF_CRYPTO_SCALAR};
                adf_argon2_fill_t fast = {memory, lanes, lane_length, 3, type, threads, backend};
                adf_argon2_fill(&scalar);
                adf_argon2_fill(&fast);
                checks++;
                if (memcmp(reference, memory, blocks * 1024) != 0) failures++;
            }
            adf_argon2_release(reference, blocks);
            adf_argon2_release(memory, blocks);
        }
    }
}

int main(int argc, char **argv) {
    for (int backend = ADF_CRYPTO_SCALAR; backend <= ADF_CRYPTO_AVX2; backend++) {
        if (adf_crypto_resolve(backend) != backend) continue;
        const int before = failures, counted = checks;
        check_blocks(backend, NULL);
        check_blake2b(backend);
        check_fills(backend);
        printf("  %-10s %d checks, %d failures\n", adf_crypto_backend_name(backend), checks - counted, failures - before);
    }
    (void)argc;
    (void)argv;
    return failures == 0 ? 0 : 1;
}

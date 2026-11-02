// libFuzzer target for the cryptographic kernels: BLAKE2b's F and Argon2's G on every backend this CPU runs against the
// scalar reference, from fuzzed states, blocks, counters and flags; `adf_crypto_equal` against a plain comparison; and
// `adf_crypto_wipe` zeroing exactly its bytes. Run by Scripts/kernels-fuzz.sh.
#include "CAemiArgon2.h"
#include "../../Sources/CAemiArgon2/adf_argon2_internal.h"

#include <stdlib.h>
#include <string.h>

#define REQUIRE(cond)                                                                                                            \
    do {                                                                                                                         \
        if (!(cond)) __builtin_trap();                                                                                           \
    } while (0)

static void words(uint64_t *out, size_t count, const uint8_t *data, size_t size) {
    for (size_t i = 0; i < count; i++) {
        uint64_t w = 0;
        for (int b = 0; b < 8; b++) w = w << 8 | (size ? data[(i * 8 + (size_t)b) % size] : 0);
        out[i] = w ^ (0x9e3779b97f4a7c15u * (i + 1));
    }
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size);
int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    if (size < 2) return 0;
    const uint8_t kind = data[0];
    data += 1;
    size -= 1;
    switch (kind % 4) {
        case 0: {
            uint64_t state[8], block[16], expected[8];
            words(state, 8, data, size);
            words(block, 16, data + size / 2, size - size / 2);
            const uint64_t low = state[0] ^ block[3], high = (uint64_t)(kind >> 7);
            const int last = (kind >> 6) & 1;
            memcpy(expected, state, sizeof state);
            adf_blake2b_compress(expected, block, low, high, last, ADF_CRYPTO_SCALAR);
            for (int backend = ADF_CRYPTO_SCALAR; backend <= ADF_CRYPTO_AVX2; backend++) {
                if (adf_crypto_resolve(backend) != backend) continue;
                uint64_t actual[8];
                memcpy(actual, state, sizeof state);
                adf_blake2b_compress(actual, block, low, high, last, backend);
                REQUIRE(memcmp(actual, expected, sizeof actual) == 0);
            }
            break;
        }
        case 1: {
            uint64_t *prev = malloc(1024), *ref = malloc(1024), *start = malloc(1024), *expected = malloc(1024), *actual = malloc(1024);
            words(prev, 128, data, size);
            words(ref, 128, data + size / 3, size - size / 3);
            words(start, 128, data + size / 2, size - size / 2);
            const int with_xor = kind >> 7;
            memcpy(expected, start, 1024);
            adf_argon2_block_scalar(expected, prev, ref, with_xor);
            for (int backend = ADF_CRYPTO_SCALAR; backend <= ADF_CRYPTO_AVX2; backend++) {
                if (adf_crypto_resolve(backend) != backend) continue;
                memcpy(actual, start, 1024);
                adf_argon2_block(actual, prev, ref, with_xor, backend);
                REQUIRE(memcmp(actual, expected, 1024) == 0);
            }
            free(prev); free(ref); free(start); free(expected); free(actual);
            break;
        }
        case 2: {
            const size_t half = size / 2;
            uint8_t *a = malloc(half ? half : 1), *b = malloc(half ? half : 1);
            memcpy(a, data, half);
            memcpy(b, data + half, half);
            REQUIRE(adf_crypto_equal(a, b, half) == (memcmp(a, b, half) == 0));
            REQUIRE(adf_crypto_equal(a, a, half) == 1);
            free(a);
            free(b);
            break;
        }
        default: {
            uint8_t *buffer = malloc(size);
            memcpy(buffer, data, size);
            const size_t from = (size_t)data[0] % size, length = size - from;
            adf_crypto_wipe(buffer + from, length);
            for (size_t i = 0; i < size; i++) REQUIRE(i < from ? buffer[i] == data[i] : buffer[i] == 0);
            free(buffer);
            break;
        }
    }
    return 0;
}

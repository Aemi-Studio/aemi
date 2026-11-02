//
//  kernels_fuzz.c
//  libFuzzer target for CAemiKernels' scanners, folding, UTF-8 and UTF-16, CRC-32C, counts, Hamming, sets, pair sets and dates:
//  the first byte picks a kernel, the next ones its parameters, the rest is the input. Every backend must agree with the
//  scalar reference on any input; buffers are exact-size heap allocations, so with AddressSanitizer a stray access is a
//  finding. Run by Scripts/kernels-fuzz.sh.
//
#include "CAemiKernels.h"

#include <stdlib.h>
#include <string.h>

#define REQUIRE(cond)                                                                                                            \
    do {                                                                                                                         \
        if (!(cond)) __builtin_trap();                                                                                           \
    } while (0)

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size);
int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    if (size < 8) return 0;
    const uint8_t kind = data[0], p1 = data[1], p2 = data[2], p3 = data[3], p4 = data[4], p5 = data[5], p6 = data[6];
    data += 7;
    size -= 7;
    uint8_t *buf = malloc(size ? size : 1);
    if (size) memcpy(buf, data, size);
    switch (kind % 12) {
        case 0: {
            const size_t r = adf_index_of_string_stop_scalar(buf, size, p1, p2);
            REQUIRE(adf_index_of_string_stop(buf, size, p1, p2) == r);
            REQUIRE(adf_index_of_string_stop_sse2(buf, size, p1, p2) == r);
            REQUIRE(adf_index_of_string_stop_avx2(buf, size, p1, p2) == r);
            REQUIRE(adf_index_of_string_stop_neon(buf, size, p1, p2) == r);
            break;
        }
        case 1: {
            const size_t r = adf_index_of_nonascii_scalar(buf, size);
            REQUIRE(adf_index_of_nonascii(buf, size) == r && adf_index_of_nonascii_sse2(buf, size) == r);
            REQUIRE(adf_index_of_nonascii_avx2(buf, size) == r && adf_index_of_nonascii_neon(buf, size) == r);
            break;
        }
        case 2:
            REQUIRE(adf_index_of_any5(buf, size, p1, p2, p3, p4, p5) == adf_index_of_any5_scalar(buf, size, p1, p2, p3, p4, p5));
            REQUIRE(adf_index_of_control_or_any5(buf, size, p1, p2, p3, p4, p5) ==
                    adf_index_of_control_or_any5_scalar(buf, size, p1, p2, p3, p4, p5));
            REQUIRE(adf_index_of_byte(buf, size, p1) == adf_index_of_byte_scalar(buf, size, p1));
            break;
        case 3:
            REQUIRE(adf_first_disallowed_text(buf, size, p1, p2 & 1) == adf_first_disallowed_text_scalar(buf, size, p1, p2 & 1));
            break;
        case 4: {
            uint8_t *a = malloc(size + 1), *b = malloc(size + 1);
            adf_fold_ascii_scalar(b, buf, size);
            adf_fold_ascii(a, buf, size);
            REQUIRE(memcmp(a, b, size) == 0);
            adf_fold_ascii_sse2(a, buf, size);
            REQUIRE(memcmp(a, b, size) == 0);
            adf_fold_ascii_avx2(a, buf, size);
            REQUIRE(memcmp(a, b, size) == 0);
            adf_fold_ascii_neon(a, buf, size);
            REQUIRE(memcmp(a, b, size) == 0);
            adf_fold_ascii(buf, buf, size);  // in place
            REQUIRE(memcmp(buf, b, size) == 0);
            free(a);
            free(b);
            break;
        }
        case 5:
            REQUIRE(adf_first_invalid_utf8(buf, size) == adf_first_invalid_utf8_scalar(buf, size));
            break;
        case 6: {
            const uint32_t seed = (uint32_t)p1 | (uint32_t)p2 << 8 | (uint32_t)p3 << 16 | (uint32_t)p4 << 24;
            const uint32_t whole = adf_crc32c_update_scalar(seed, buf, size);
            REQUIRE(adf_crc32c_update(seed, buf, size) == whole);
            const size_t split = size ? (size_t)p5 * 37 % (size + 1) : 0;
            REQUIRE(adf_crc32c_update(adf_crc32c_update(seed, buf, split), buf + split, size - split) == whole);
            REQUIRE(adf_bit_count(buf, size) == adf_bit_count_scalar(buf, size));
            break;
        }
        case 7: {
            const size_t half = size / 2;
            REQUIRE(adf_hamming_distance(buf, buf + half, half) == adf_hamming_distance_scalar(buf, buf + half, half));
            const size_t width = p1 ? p1 : 1, count = width <= size ? size / width - (size / width > 0) : 0;
            if (count > 0) {
                uint32_t *out = malloc(count * sizeof(uint32_t));
                adf_hamming_scan(buf, buf + width, width, count, out);
                for (size_t v = 0; v < count; v++) REQUIRE(out[v] == adf_hamming_distance_scalar(buf, buf + width * (v + 1), width));
                free(out);
            }
            break;
        }
        case 8: {
            const size_t units = size / 2;
            uint8_t *a = malloc(units + 1), *b = malloc(units + 1);
            const size_t r = adf_utf16le_ascii_prefix_scalar(buf, units, b);
            REQUIRE(adf_utf16le_ascii_prefix(buf, units, a) == r && memcmp(a, b, r) == 0);
            free(a);
            free(b);
            break;
        }
        case 9: {
            // A set from the parameters: two nibble tables of any content (the kernels must agree whatever they hold).
            uint8_t lo[16], hi[16];
            for (int i = 0; i < 16; i++) {
                lo[i] = (uint8_t)((p1 >> (i % 8)) & 1 ? p2 : p3);
                hi[i] = (uint8_t)((p4 >> (i % 8)) & 1 ? p5 : p6);
            }
            REQUIRE(adf_index_of_set(buf, size, lo, hi) == adf_index_of_set_scalar(buf, size, lo, hi));
            break;
        }
        case 10: {
            uint8_t table[64];
            for (int i = 0; i < 64; i++) table[i] = (uint8_t)(1u << ((i + p1) % 8)) & (uint8_t)(i % 3 == 0 ? p2 : p3);
            const size_t from = size ? (size_t)p4 % (size + 1) : 0;
            REQUIRE(adf_pair_set_find(table, buf, size, from) == adf_pair_set_find_scalar(table, buf, size, from));
            break;
        }
        default: {
            // A date: the input's first 20 bytes, or the canonical shape with the input's digits.
            int64_t got = 0;
            const int ok = adf_parse_iso8601_utc(buf, size, &got);
            REQUIRE(ok == 0 || size == 20);
            if (size >= 14) {
                char text[21];
                memcpy(text, "0000-00-00T00:00:00Z", 21);
                const int at[14] = {0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18};
                for (int i = 0; i < 14; i++) text[at[i]] = (char)('0' + buf[i] % 10);
                int64_t seconds = 0;
                if (adf_parse_iso8601_utc((const uint8_t *)text, 20, &seconds)) {
                    // Valid: every field in range, and the seconds of the day are the time's.
                    REQUIRE(((seconds % 86400) + 86400) % 86400 ==
                            ((text[11] - '0') * 10 + (text[12] - '0')) * 3600 + ((text[14] - '0') * 10 + (text[15] - '0')) * 60 +
                                (text[17] - '0') * 10 + (text[18] - '0'));
                }
            }
            break;
        }
    }
    free(buf);
    return 0;
}

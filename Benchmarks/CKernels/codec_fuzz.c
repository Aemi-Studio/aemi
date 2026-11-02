//
//  codec_fuzz.c
//  libFuzzer target for CAemiKernels' codec and search kernels: the first byte picks a kernel and its parameters, the rest is
//  the input. For any input, every backend must agree with the scalar reference, and each encoding must decode back to its
//  input; any difference is a trap the fuzzer reports. Buffers are exact-size heap allocations, so with AddressSanitizer an
//  access outside them is a finding. Run by Scripts/kernels-fuzz.sh (natively, and as x86-64 under Rosetta).
//
#include "CAemiKernels.h"

#include <stdlib.h>
#include <string.h>

#define REQUIRE(cond)                                                                                                            \
    do {                                                                                                                         \
        if (!(cond)) __builtin_trap();                                                                                           \
    } while (0)

static uint8_t *copy(const uint8_t *data, size_t n) {
    uint8_t *p = malloc(n ? n : 1);
    if (n) memcpy(p, data, n);
    return p;
}

typedef struct {
    uint8_t table[64], lut[256];
    uint16_t tail;
} Alphabet;

static Alphabet alphabet(int which) {
    static const char *base = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    char symbols[64];
    memcpy(symbols, base, 62);
    symbols[62] = which == 1 ? '-' : '+';
    symbols[63] = which == 1 ? '_' : '/';
    if (which == 2) {
        for (int i = 63; i > 0; i--) {
            const int j = (i * 37 + 11) % (i + 1);
            const char t = symbols[i];
            symbols[i] = symbols[j];
            symbols[j] = t;
        }
    }
    Alphabet a;
    memset(a.lut, 0xFF, sizeof a.lut);
    for (int i = 0; i < 64; i++) {
        a.table[i] = (uint8_t)symbols[i];
        a.lut[(uint8_t)symbols[i]] = (uint8_t)i;
    }
    a.tail = which == 2 ? 0 : (uint16_t)((uint8_t)symbols[62] | (uint16_t)((uint8_t)symbols[63] << 8));
    return a;
}

static void fuzz_base64(const uint8_t *data, size_t n, uint8_t selector, uint8_t width_byte) {
    const Alphabet a = alphabet(selector % 3);
    // Decode the input as text, every backend.
    uint8_t *text = copy(data, n);
    uint8_t *reference = malloc(n / 4 * 3 + 1), *out = malloc(n / 4 * 3 + 1);
    const size_t expected = adf_b64_decode_blocks_scalar(a.lut, text, n, reference);
    REQUIRE(adf_b64_decode_blocks(a.lut, a.tail, text, n, out) == expected && memcmp(out, reference, expected / 4 * 3) == 0);
    REQUIRE(adf_b64_decode_blocks_ssse3(a.lut, a.tail, text, n, out) == expected && memcmp(out, reference, expected / 4 * 3) == 0);
    REQUIRE(adf_b64_decode_blocks_avx2(a.lut, a.tail, text, n, out) == expected && memcmp(out, reference, expected / 4 * 3) == 0);
    // As wrapped text of some width.
    const size_t width = (size_t)width_byte;
    uint8_t *lines = malloc(n + 1), *linesRef = malloc(n + 1);
    size_t w1 = 0, w2 = 0;
    const size_t c1 = adf_b64_decode_lines(a.lut, a.tail, text, n, lines, n, width, &w1);
    const size_t c2 = adf_b64_decode_lines_scalar(a.lut, text, n, linesRef, n, width, &w2);
    REQUIRE(c1 == c2 && w1 == w2 && memcmp(lines, linesRef, w1) == 0);
    // Encode the input as bytes, every backend, then decode it back.
    uint8_t *symbols = malloc(n / 3 * 4 + 1), *symbolsRef = malloc(n / 3 * 4 + 1);
    adf_b64_encode_blocks_scalar(a.table, text, n, symbolsRef);
    REQUIRE(adf_b64_encode_blocks(a.table, a.tail, text, n, symbols) == n / 3 * 3 && memcmp(symbols, symbolsRef, n / 3 * 4) == 0);
    REQUIRE(adf_b64_encode_blocks_ssse3(a.table, a.tail, text, n, symbols) == n / 3 * 3 && memcmp(symbols, symbolsRef, n / 3 * 4) == 0);
    REQUIRE(adf_b64_encode_blocks_avx2(a.table, a.tail, text, n, symbols) == n / 3 * 3 && memcmp(symbols, symbolsRef, n / 3 * 4) == 0);
    uint8_t *back = malloc(n / 3 * 3 + 1);
    REQUIRE(adf_b64_decode_blocks(a.lut, a.tail, symbols, n / 3 * 4, back) == n / 3 * 4 && memcmp(back, text, n / 3 * 3) == 0);
    // Wrapped encoding, then its lines decoded back.
    const size_t lineWidth = (width / 4) * 4;
    if (lineWidth > 0) {
        const int crlf = selector & 4;
        const size_t cap = n / 3 * 4 + 4 + (n / (lineWidth / 4 * 3) + 1) * 2;
        uint8_t *wrapped = malloc(cap), *wrappedRef = malloc(cap);
        size_t e1 = 0, e2 = 0;
        const size_t k1 = adf_b64_encode_lines(a.table, a.tail, text, n, wrapped, cap, lineWidth, crlf, &e1);
        const size_t k2 = adf_b64_encode_lines_scalar(a.table, text, n, wrappedRef, cap, lineWidth, crlf, &e2);
        REQUIRE(k1 == k2 && e1 == e2 && memcmp(wrapped, wrappedRef, e1) == 0);
        uint8_t *unwrapped = malloc(k1 + 1);
        size_t d = 0;
        REQUIRE(adf_b64_decode_lines(a.lut, a.tail, wrapped, e1, unwrapped, k1, lineWidth, &d) == e1 && d == k1);
        REQUIRE(memcmp(unwrapped, text, k1) == 0);
        free(wrapped);
        free(wrappedRef);
        free(unwrapped);
    }
    free(text); free(reference); free(out); free(lines); free(linesRef); free(symbols); free(symbolsRef); free(back);
}

static void fuzz_hex(const uint8_t *data, size_t n, uint8_t selector) {
    uint8_t *text = copy(data, n);
    uint8_t *reference = malloc(n / 2 + 1), *out = malloc(n / 2 + 1);
    const size_t expected = adf_hex_decode_scalar(text, n, reference);
    REQUIRE(adf_hex_decode(text, n, out) == expected && memcmp(out, reference, expected / 2) == 0);
    REQUIRE(adf_hex_decode_ssse3(text, n, out) == expected && memcmp(out, reference, expected / 2) == 0);
    REQUIRE(adf_hex_decode_avx2(text, n, out) == expected && memcmp(out, reference, expected / 2) == 0);
    const int upper = selector & 1;
    uint8_t *digits = malloc(2 * n + 1), *digitsRef = malloc(2 * n + 1), *back = malloc(n + 1);
    adf_hex_encode_scalar(text, n, digitsRef, upper);
    adf_hex_encode(text, n, digits, upper);
    REQUIRE(memcmp(digits, digitsRef, 2 * n) == 0);
    adf_hex_encode_ssse3(text, n, digits, upper);
    REQUIRE(memcmp(digits, digitsRef, 2 * n) == 0);
    adf_hex_encode_avx2(text, n, digits, upper);
    REQUIRE(memcmp(digits, digitsRef, 2 * n) == 0);
    REQUIRE(adf_hex_decode(digits, 2 * n, back) == 2 * n && memcmp(back, text, n) == 0);
    free(text); free(reference); free(out); free(digits); free(digitsRef); free(back);
}

static void fuzz_percent(const uint8_t *data, size_t n, uint8_t selector) {
    // The set: the reserved bytes of RFC 3986, or (selector) a set from the input's first bytes.
    uint8_t lo[16], hi[16];
    memset(lo, 0, 16);
    memset(hi, 0, 16);
    for (int b = 0; b < 256; b++) {
        const int unreserved = (b >= 'A' && b <= 'Z') || (b >= 'a' && b <= 'z') || (b >= '0' && b <= '9') || b == '-' || b == '.' ||
                               b == '_' || b == '~';
        const int member = (selector & 1) ? !unreserved : (b == '%' || b == ' ' || b >= 0x80);
        if (member) {
            // One bucket per high nibble class is enough for a test set: bit (b >> 4) % 8.
            const uint8_t bit = (uint8_t)(1u << ((b >> 4) % 8));
            lo[b & 15] |= bit;
            hi[b >> 4] |= bit;
        }
    }
    uint8_t *text = copy(data, n);
    const size_t count = adf_count_in_set(text, n, lo, hi);
    REQUIRE(count == adf_count_in_set_scalar(text, n, lo, hi));
    const size_t cap = n + 2 * count;
    uint8_t *enc = malloc(cap + 1), *encRef = malloc(cap + 1);
    REQUIRE(adf_percent_encode(text, n, lo, hi, enc, cap) == cap);
    REQUIRE(adf_percent_encode_scalar(text, n, lo, hi, encRef, cap) == cap && memcmp(enc, encRef, cap) == 0);
    if (cap > 0) REQUIRE(adf_percent_encode(text, n, lo, hi, enc, cap - 1) == SIZE_MAX);
    for (int plus = 0; plus < 2; plus++) {
        uint8_t *out = malloc(n + 1), *outRef = malloc(n + 1);
        size_t b1 = 0, b2 = 0;
        const size_t r1 = adf_percent_decode(text, n, out, plus, &b1);
        const size_t r2 = adf_percent_decode_scalar(text, n, outRef, plus, &b2);
        REQUIRE(r1 == r2 && (r1 == SIZE_MAX ? b1 == b2 : memcmp(out, outRef, r1) == 0));
        free(out);
        free(outRef);
    }
    free(text); free(enc); free(encRef);
}

static void fuzz_find(const uint8_t *data, size_t n, uint8_t split) {
    const size_t nlen = n == 0 ? 0 : (size_t)split % (n + 1);
    uint8_t *needle = copy(data, nlen), *hay = copy(data + nlen, n - nlen);
    const size_t expected = adf_find_scalar(hay, n - nlen, needle, nlen);
    size_t (*const finders[])(const uint8_t *, size_t, const uint8_t *, size_t, size_t *) = {adf_find, adf_find_sse2, adf_find_avx2};
    for (int f = 0; f < 3; f++) {
        size_t resume = 0;
        const size_t got = finders[f](hay, n - nlen, needle, nlen, &resume);
        if (got == ADF_FIND_GAVE_UP) {
            REQUIRE(resume + nlen <= n - nlen && (expected == SIZE_MAX || expected >= resume));
        } else {
            REQUIRE(got == expected);
        }
    }
    free(needle);
    free(hay);
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size);
int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    if (size < 3) return 0;
    const uint8_t kind = data[0], a = data[1], b = data[2];
    data += 3;
    size -= 3;
    switch (kind % 4) {
        case 0: fuzz_base64(data, size, a, b); break;
        case 1: fuzz_hex(data, size, a); break;
        case 2: fuzz_percent(data, size, a); break;
        default: fuzz_find(data, size, b); break;
    }
    return 0;
}

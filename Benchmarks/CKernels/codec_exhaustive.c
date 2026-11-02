//
//  codec_exhaustive.c
//  Exhaustive and edge checks of CAemiKernels' codec and search kernels (Base64 blocks and lines, hex, percent-coding, byte
//  search), every backend against the scalar reference: every byte value at every position of inputs around each vector width,
//  inputs flush against inaccessible pages at both ends (an access one byte outside crashes), every %XY pair, and every binary
//  haystack and needle up to a length. Built with AddressSanitizer and UBSan by Scripts/kernels-check.sh, which runs it
//  natively and as x86-64 under Rosetta (SSSE3, then AVX2). Exit 1 on any difference.
//
#include "CAemiKernels.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

static long failures = 0, checks = 0;

#define EXPECT(cond, ...)                                                                                                       \
    do {                                                                                                                        \
        checks++;                                                                                                               \
        if (!(cond)) {                                                                                                          \
            if (failures++ < 12) {                                                                                              \
                printf("FAIL %s:%d: ", __FILE__, __LINE__);                                                                     \
                printf(__VA_ARGS__);                                                                                            \
                printf("\n");                                                                                                   \
            }                                                                                                                   \
        }                                                                                                                       \
    } while (0)

// MARK: - Guarded memory

typedef struct {
    uint8_t *mapping;
    size_t length;
    uint8_t *bytes;
} Guarded;

/// `count` writable bytes with an inaccessible page right after them (`at_end`) or right before them.
static Guarded guarded(size_t count, int at_end) {
    const size_t page = (size_t)getpagesize();
    const size_t pages = count / page + 1;
    Guarded g;
    g.length = (pages + 2) * page;
    g.mapping = mmap(NULL, g.length, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (g.mapping == MAP_FAILED) abort();
    mprotect(g.mapping, page, PROT_NONE);
    mprotect(g.mapping + (pages + 1) * page, page, PROT_NONE);
    g.bytes = at_end ? g.mapping + (pages + 1) * page - count : g.mapping + page;
    return g;
}

static void release(Guarded g) { munmap(g.mapping, g.length); }

// MARK: - Base64

static const char *std_symbols = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

typedef struct {
    uint8_t table[64], lut[256];
    uint16_t tail;
    const char *name;
} Alphabet;

static Alphabet alphabet(const char *name, char plus, char slash, int shuffle) {
    Alphabet a;
    char symbols[64];
    memcpy(symbols, std_symbols, 62);
    symbols[62] = plus;
    symbols[63] = slash;
    if (shuffle) {
        for (int i = 63; i > 0; i--) {
            const int j = (i * 37 + 11) % (i + 1);
            const char t = symbols[i];
            symbols[i] = symbols[j];
            symbols[j] = t;
        }
    }
    memset(a.lut, 0xFF, sizeof a.lut);
    for (int i = 0; i < 64; i++) {
        a.table[i] = (uint8_t)symbols[i];
        a.lut[(uint8_t)symbols[i]] = (uint8_t)i;
    }
    a.tail = shuffle ? 0 : (uint16_t)((uint8_t)plus | (uint16_t)((uint8_t)slash << 8));
    a.name = name;
    return a;
}

typedef size_t (*B64Encode)(const uint8_t *, uint16_t, const uint8_t *, size_t, uint8_t *);
typedef size_t (*B64Decode)(const uint8_t *, uint16_t, const uint8_t *, size_t, uint8_t *);
static const struct { const char *name; B64Encode encode; B64Decode decode; } b64_backends[] = {
    {"dispatched", adf_b64_encode_blocks, adf_b64_decode_blocks},
    {"ssse3", adf_b64_encode_blocks_ssse3, adf_b64_decode_blocks_ssse3},
    {"avx2", adf_b64_encode_blocks_avx2, adf_b64_decode_blocks_avx2},
};

/// Every byte value at every position of valid text, for lengths around every step (4, 16, 32, 64 symbols), guarded at both ends.
static void base64_decode_every_byte_everywhere(const Alphabet *a) {
    for (size_t len = 0; len <= 140; len += (len < 40 ? 1 : 4)) {
        for (int end = 0; end < 2; end++) {
            Guarded text = guarded(len, end);
            Guarded fast = guarded(len / 4 * 3, end);
            uint8_t reference[256];
            for (size_t i = 0; i < len; i++) text.bytes[i] = a->table[(i * 7 + 3) % 64];
            for (size_t p = 0; p < len; p++) {
                const uint8_t keep = text.bytes[p];
                for (int v = 0; v < 256; v++) {
                    text.bytes[p] = (uint8_t)v;
                    const size_t expected = adf_b64_decode_blocks_scalar(a->lut, text.bytes, len, reference);
                    for (size_t b = 0; b < 3; b++) {
                        const size_t got = b64_backends[b].decode(a->lut, a->tail, text.bytes, len, fast.bytes);
                        EXPECT(got == expected && memcmp(fast.bytes, reference, got / 4 * 3) == 0,
                               "b64 decode %s %s len %zu pos %zu byte %d: %zu vs %zu", a->name, b64_backends[b].name, len, p, v, got,
                               expected);
                    }
                }
                text.bytes[p] = keep;
            }
            release(text);
            release(fast);
        }
    }
}

static void base64_encode_every_byte_everywhere(const Alphabet *a) {
    for (size_t len = 0; len <= 100; len++) {
        for (int end = 0; end < 2; end++) {
            Guarded in = guarded(len, end);
            Guarded out = guarded(len / 3 * 4, end);
            uint8_t reference[256];
            for (size_t i = 0; i < len; i++) in.bytes[i] = (uint8_t)(i * 31 + 7);
            for (size_t p = 0; p < len; p += (len > 50 ? 3 : 1)) {
                const uint8_t keep = in.bytes[p];
                for (int v = 0; v < 256; v++) {
                    in.bytes[p] = (uint8_t)v;
                    adf_b64_encode_blocks_scalar(a->table, in.bytes, len, reference);
                    for (size_t b = 0; b < 3; b++) {
                        const size_t got = b64_backends[b].encode(a->table, a->tail, in.bytes, len, out.bytes);
                        EXPECT(got == len / 3 * 3 && memcmp(out.bytes, reference, len / 3 * 4) == 0, "b64 encode %s %s len %zu pos %zu",
                               a->name, b64_backends[b].name, len, p);
                    }
                }
                in.bytes[p] = keep;
            }
            release(in);
            release(out);
        }
    }
}

/// Wrapped text: a damaging byte at every position (and a byte removed at every position), widths 16, 64 and 76, LF and CR LF.
static void base64_lines(const Alphabet *a) {
    const uint8_t damage[] = {0x0A, 0x0D, '=', '!', ' ', 0x80, 0xFF, 0x00, 'A', '/'};
    const size_t widths[] = {16, 64, 76};
    for (size_t w = 0; w < 3; w++) {
        for (int crlf = 0; crlf < 2; crlf++) {
            const size_t width = widths[w], lines = 4, ending = crlf ? 2 : 1;
            const size_t len = lines * (width + ending);
            uint8_t valid[400];
            size_t k = 0;
            for (size_t l = 0; l < lines; l++) {
                for (size_t i = 0; i < width; i++) valid[k++] = a->table[(l * 13 + i * 5) % 64];
                if (crlf) valid[k++] = 0x0D;
                valid[k++] = 0x0A;
            }
            for (size_t p = 0; p < len; p++) {
                for (size_t d = 0; d < sizeof damage + 1; d++) {
                    // d == sizeof damage: the byte at p removed.
                    const size_t n = d == sizeof damage ? len - 1 : len;
                    Guarded text = guarded(n, (int)(p & 1));
                    if (d == sizeof damage) {
                        memcpy(text.bytes, valid, p);
                        memcpy(text.bytes + p, valid + p + 1, len - p - 1);
                    } else {
                        memcpy(text.bytes, valid, len);
                        text.bytes[p] = damage[d];
                    }
                    const size_t cap = n;
                    Guarded out = guarded(cap, 1);
                    uint8_t reference[400];
                    size_t wf = 0, wr = 0;
                    const size_t cf = adf_b64_decode_lines(a->lut, a->tail, text.bytes, n, out.bytes, cap, width, &wf);
                    const size_t cr = adf_b64_decode_lines_scalar(a->lut, text.bytes, n, reference, cap, width, &wr);
                    EXPECT(cf == cr && wf == wr && memcmp(out.bytes, reference, wr) == 0, "b64 lines %s width %zu crlf %d pos %zu damage %zu",
                           a->name, width, crlf, p, d);
                    release(text);
                    release(out);
                }
            }
        }
    }
    // Encoding lines: every length to 300 into a guarded output of exactly the encoded size.
    for (size_t w = 0; w < 3; w++) {
        for (size_t n = 0; n <= 300; n++) {
            for (int crlf = 0; crlf < 2; crlf++) {
                const size_t width = widths[w], bytes = width / 4 * 3;
                const size_t full = n == 0 ? 0 : (n - 1) / bytes;  // lines with an ending after them
                const size_t cap = full * (width + (crlf ? 2u : 1u));
                Guarded in = guarded(n, 1);
                for (size_t i = 0; i < n; i++) in.bytes[i] = (uint8_t)(i * 11 + 5);
                Guarded out = guarded(cap, 1);
                uint8_t reference[600];
                size_t wf = 0, wr = 0;
                const size_t cf = adf_b64_encode_lines(a->table, a->tail, in.bytes, n, out.bytes, cap, width, crlf, &wf);
                const size_t cr = adf_b64_encode_lines_scalar(a->table, in.bytes, n, reference, cap, width, crlf, &wr);
                EXPECT(cf == cr && wf == wr && cf == full * bytes && memcmp(out.bytes, reference, wr) == 0,
                       "b64 encode lines %s width %zu n %zu crlf %d", a->name, width, n, crlf);
                // With room to spare it still stops before the last line: an ending is written only between lines.
                uint8_t roomy[700];
                size_t wroomy = 0;
                const size_t croomy = adf_b64_encode_lines(a->table, a->tail, in.bytes, n, roomy, sizeof roomy, width, crlf, &wroomy);
                EXPECT(croomy == full * bytes && wroomy == cap, "b64 encode lines roomy %s width %zu n %zu: %zu", a->name, width, n, croomy);
                release(in);
                release(out);
            }
        }
    }
}

// MARK: - Hex

typedef void (*HexEncode)(const uint8_t *, size_t, uint8_t *, int);
typedef size_t (*HexDecode)(const uint8_t *, size_t, uint8_t *);
static const struct { const char *name; HexEncode encode; HexDecode decode; } hex_backends[] = {
    {"dispatched", adf_hex_encode, adf_hex_decode},
    {"ssse3", adf_hex_encode_ssse3, adf_hex_decode_ssse3},
    {"avx2", adf_hex_encode_avx2, adf_hex_decode_avx2},
};

static void hex_every_byte_everywhere(void) {
    for (size_t len = 0; len <= 100; len++) {
        for (int end = 0; end < 2; end++) {
            Guarded text = guarded(len, end);
            Guarded out = guarded(len / 2, end);
            uint8_t reference[64];
            for (size_t i = 0; i < len; i++) text.bytes[i] = (uint8_t)"0123456789abcdefABCDEF"[(i * 5 + 1) % 22];
            for (size_t p = 0; p < len; p++) {
                const uint8_t keep = text.bytes[p];
                for (int v = 0; v < 256; v++) {
                    text.bytes[p] = (uint8_t)v;
                    const size_t expected = adf_hex_decode_scalar(text.bytes, len, reference);
                    for (size_t b = 0; b < 3; b++) {
                        const size_t got = hex_backends[b].decode(text.bytes, len, out.bytes);
                        EXPECT(got == expected && memcmp(out.bytes, reference, got / 2) == 0, "hex decode %s len %zu pos %zu byte %d",
                               hex_backends[b].name, len, p, v);
                    }
                }
                text.bytes[p] = keep;
            }
            release(text);
            release(out);
        }
    }
    for (size_t len = 0; len <= 100; len++) {
        for (int upper = 0; upper < 2; upper++) {
            Guarded in = guarded(len, upper);
            Guarded out = guarded(2 * len, upper);
            uint8_t reference[256];
            for (int round = 0; round < 256; round++) {
                for (size_t i = 0; i < len; i++) in.bytes[i] = (uint8_t)(round + (int)i * 97);
                adf_hex_encode_scalar(in.bytes, len, reference, upper);
                for (size_t b = 0; b < 3; b++) {
                    hex_backends[b].encode(in.bytes, len, out.bytes, upper);
                    EXPECT(memcmp(out.bytes, reference, 2 * len) == 0, "hex encode %s len %zu round %d", hex_backends[b].name, len, round);
                }
            }
            release(in);
            release(out);
        }
    }
}

// MARK: - Percent-coding

static int reserved(int b) {
    return !((b >= 'A' && b <= 'Z') || (b >= 'a' && b <= 'z') || (b >= '0' && b <= '9') || b == '-' || b == '.' || b == '_' || b == '~');
}

static void set_tables(uint8_t lo[16], uint8_t hi[16]) {
    uint16_t rows[16] = {0}, patterns[8];
    int count = 0;
    memset(lo, 0, 16);
    memset(hi, 0, 16);
    for (int b = 0; b < 256; b++) if (reserved(b)) rows[b >> 4] |= (uint16_t)(1u << (b & 15));
    for (int up = 0; up < 16; up++) {
        if (!rows[up]) continue;
        int bit = -1;
        for (int k = 0; k < count; k++) if (patterns[k] == rows[up]) bit = k;
        if (bit < 0) {
            patterns[count] = rows[up];
            bit = count++;
        }
        hi[up] = (uint8_t)(1u << bit);
        for (int low = 0; low < 16; low++) if (rows[up] & (1u << low)) lo[low] |= (uint8_t)(1u << bit);
    }
}

static void percent_every_byte_everywhere(void) {
    uint8_t lo[16], hi[16];
    set_tables(lo, hi);
    // Decode: every byte at every position of text with escapes, as is and as a form.
    for (size_t len = 0; len <= 70; len++) {
        Guarded text = guarded(len, 1);
        Guarded out = guarded(len, 1);
        uint8_t reference[128];
        for (size_t i = 0; i < len; i++) text.bytes[i] = (uint8_t)"ab%41c+d%2fe"[i % 12];
        for (size_t p = 0; p < len; p++) {
            const uint8_t keep = text.bytes[p];
            for (int v = 0; v < 256; v++) {
                text.bytes[p] = (uint8_t)v;
                for (int plus = 0; plus < 2; plus++) {
                    size_t bf = 0, br = 0;
                    const size_t rf = adf_percent_decode(text.bytes, len, out.bytes, plus, &bf);
                    const size_t rr = adf_percent_decode_scalar(text.bytes, len, reference, plus, &br);
                    EXPECT(rf == rr && (rr == SIZE_MAX ? bf == br : memcmp(out.bytes, reference, rr) == 0),
                           "percent decode len %zu pos %zu byte %d plus %d", len, p, v, plus);
                }
            }
            text.bytes[p] = keep;
        }
        release(text);
        release(out);
    }
    // Every %XY at positions around the block edges.
    const size_t positions[] = {0, 1, 12, 13, 14, 15, 16, 29, 30, 31, 45};
    for (size_t q = 0; q < sizeof positions / sizeof positions[0]; q++) {
        const size_t len = 48;
        Guarded text = guarded(len, 1);
        Guarded out = guarded(len, 1);
        uint8_t reference[64];
        memset(text.bytes, 'z', len);
        const size_t p = positions[q];
        for (int x = 0; x < 256; x++) {
            for (int y = 0; y < 256; y++) {
                text.bytes[p] = '%';
                if (p + 1 < len) text.bytes[p + 1] = (uint8_t)x;
                if (p + 2 < len) text.bytes[p + 2] = (uint8_t)y;
                size_t bf = 0, br = 0;
                const size_t rf = adf_percent_decode(text.bytes, len, out.bytes, 1, &bf);
                const size_t rr = adf_percent_decode_scalar(text.bytes, len, reference, 1, &br);
                EXPECT(rf == rr && (rr == SIZE_MAX ? bf == br : memcmp(out.bytes, reference, rr) == 0), "percent %%XY at %zu: %d %d", p, x, y);
            }
        }
        release(text);
        release(out);
    }
    // Encode: every byte at every position, into a guarded output of exactly the encoded size.
    for (size_t len = 0; len <= 70; len++) {
        Guarded in = guarded(len, 0);
        uint8_t reference[256];
        for (size_t i = 0; i < len; i++) in.bytes[i] = (uint8_t)("abcdefghij/ k"[i % 13]);
        for (size_t p = 0; p < len; p++) {
            const uint8_t keep = in.bytes[p];
            for (int v = 0; v < 256; v++) {
                in.bytes[p] = (uint8_t)v;
                const size_t count = adf_count_in_set(in.bytes, len, lo, hi);
                EXPECT(count == adf_count_in_set_scalar(in.bytes, len, lo, hi), "percent count len %zu pos %zu byte %d", len, p, v);
                const size_t cap = len + 2 * count;
                Guarded out = guarded(cap, 1);
                const size_t wf = adf_percent_encode(in.bytes, len, lo, hi, out.bytes, cap);
                const size_t wr = adf_percent_encode_scalar(in.bytes, len, lo, hi, reference, cap);
                EXPECT(wf == cap && wr == cap && memcmp(out.bytes, reference, cap) == 0, "percent encode len %zu pos %zu byte %d", len, p, v);
                if (cap > 0) EXPECT(adf_percent_encode(in.bytes, len, lo, hi, out.bytes + 1, cap - 1) == SIZE_MAX, "percent short %zu", len);
                release(out);
            }
            in.bytes[p] = keep;
        }
        release(in);
    }
}

/// Counts over long inputs: past the 255 vectors after which a byte counter would wrap, all members, none, and every 3rd.
static void percent_long_counts(void) {
    uint8_t lo[16], hi[16];
    set_tables(lo, hi);
    const size_t lengths[] = {4079, 4080, 4081, 4095, 4096, 4097, 8191, 65536, 1 << 20};
    for (size_t k = 0; k < sizeof lengths / sizeof lengths[0]; k++) {
        const size_t len = lengths[k];
        for (int pattern = 0; pattern < 3; pattern++) {
            Guarded buf = guarded(len, (int)(k & 1));
            for (size_t i = 0; i < len; i++) buf.bytes[i] = pattern == 0 ? ' ' : pattern == 1 ? 'a' : (i % 3 == 0 ? '/' : 'b');
            const size_t count = adf_count_in_set(buf.bytes, len, lo, hi);
            const size_t expected = pattern == 0 ? len : pattern == 1 ? 0 : (len + 2) / 3;
            EXPECT(count == expected && count == adf_count_in_set_scalar(buf.bytes, len, lo, hi), "percent count %zu pattern %d: %zu", len,
                   pattern, count);
            release(buf);
        }
    }
}

// MARK: - Byte search

typedef size_t (*FindFn)(const uint8_t *, size_t, const uint8_t *, size_t, size_t *);
static const FindFn find_backends[] = {adf_find, adf_find_sse2, adf_find_avx2};

static void find_every_binary_string(void) {
    // Every haystack over {a, b} up to 13 bytes, every needle up to 5, guarded at both ends.
    for (size_t hlen = 0; hlen <= 13; hlen++) {
        for (unsigned hbits = 0; hbits < (1u << hlen); hbits++) {
            Guarded hay = guarded(hlen, (int)(hbits & 1));
            for (size_t i = 0; i < hlen; i++) hay.bytes[i] = (hbits >> i) & 1 ? 'b' : 'a';
            for (size_t nlen = 1; nlen <= 5; nlen++) {
                for (unsigned nbits = 0; nbits < (1u << nlen); nbits++) {
                    uint8_t needle[5];
                    for (size_t i = 0; i < nlen; i++) needle[i] = (nbits >> i) & 1 ? 'b' : 'a';
                    const size_t expected = adf_find_scalar(hay.bytes, hlen, needle, nlen);
                    for (int f = 0; f < 3; f++) {
                        size_t resume = 0;
                        const size_t got = find_backends[f](hay.bytes, hlen, needle, nlen, &resume);
                        EXPECT(got == expected, "find %d hay %u/%zu needle %u/%zu: %zu vs %zu", f, hbits, hlen, nbits, nlen, got, expected);
                    }
                }
            }
            release(hay);
        }
    }
    // Longer haystacks over {a, b} (every start a candidate, often) with the needle at every position and absent.
    for (size_t hlen = 14; hlen <= 140; hlen++) {
        Guarded hay = guarded(hlen, (int)(hlen & 1));
        for (size_t i = 0; i < hlen; i++) hay.bytes[i] = ((i * 7) % 5) == 0 ? 'b' : 'a';
        for (size_t nlen = 2; nlen <= 40 && nlen <= hlen; nlen += 3) {
            for (size_t at = 0; at + nlen <= hlen; at += 5) {
                uint8_t needle[40];
                memcpy(needle, hay.bytes + at, nlen);
                for (int f = 0; f < 3; f++) {
                    size_t resume = 0;
                    needle[nlen / 2] = hay.bytes[at + nlen / 2];
                    EXPECT(find_backends[f](hay.bytes, hlen, needle, nlen, &resume) == adf_find_scalar(hay.bytes, hlen, needle, nlen),
                           "find %d long %zu %zu %zu", f, hlen, nlen, at);
                    needle[nlen / 2] = 'z';
                    EXPECT(find_backends[f](hay.bytes, hlen, needle, nlen, &resume) == SIZE_MAX, "find %d absent %zu %zu", f, hlen, nlen);
                }
            }
        }
        release(hay);
    }
}

int main(void) {
    const Alphabet alphabets[] = {alphabet("standard", '+', '/', 0), alphabet("url-safe", '-', '_', 0), alphabet("shuffled", '+', '/', 1)};
    for (int a = 0; a < 3; a++) {
        base64_decode_every_byte_everywhere(&alphabets[a]);
        base64_encode_every_byte_everywhere(&alphabets[a]);
        base64_lines(&alphabets[a]);
    }
    printf("exhaustive base64 (host %s): %ld checks\n", adf_kernels_backend(), checks);
    hex_every_byte_everywhere();
    percent_every_byte_everywhere();
    percent_long_counts();
    find_every_binary_string();
    printf("exhaustive codecs (host %s): %ld checks, %ld failures\n", adf_kernels_backend(), checks, failures);
    return failures != 0;
}

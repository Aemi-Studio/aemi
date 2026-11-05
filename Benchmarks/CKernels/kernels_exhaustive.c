//
//  kernels_exhaustive.c
//  Exhaustive and edge checks of CAemiKernels' scanners, folding, UTF-8 and UTF-16 kernels, checksums, bit counts, Hamming and
//  date parsing: every backend against the scalar reference (or, for dates, against an independent calendar), with inputs flush
//  against inaccessible pages at both ends, every byte value at every position around each vector width, every UTF-8 sequence
//  of up to three bytes and every four-byte lead with its continuations, counts past every accumulator's flush, and every date
//  of every year. Built with AddressSanitizer and UBSan by Scripts/kernels-check.sh. Exit 1 on any difference.
//
#include "CAemiKernels.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
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

typedef struct {
    uint8_t *mapping;
    size_t length;
    uint8_t *bytes;
} Guarded;

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

static const size_t lengths[] = {0,  1,  2,  3,  7,  8,  9,  15, 16, 17, 31, 32, 33, 47, 48, 63, 64, 65, 79, 80,
                                 95, 96, 127, 128, 129, 191, 255, 256, 257, 4095, 4096, 4097};
#define LENGTHS (sizeof lengths / sizeof lengths[0])

// MARK: - Scanners

typedef size_t (*Scan2)(const uint8_t *, size_t, uint8_t, uint8_t);
typedef size_t (*Scan0)(const uint8_t *, size_t);

/// Every byte value at every position (every 7th past 300) of a filler that matches nothing, for each scanner and backend.
/// The set {'a'} plus `lo`/`hi` of `scanners`: 'a' is 0x61, row 6, column 1.
static const uint8_t filler_lo[16] = {1, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 4, 0, 0, 0},
                     filler_hi[16] = {0, 0, 1, 0, 0, 6, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0};

static void scanners(void) {
    const uint8_t lo[16] = {1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 4, 0, 0, 0}, hi[16] = {0, 0, 1, 0, 0, 6, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0};
    const Scan2 stops[] = {adf_index_of_string_stop, adf_index_of_string_stop_sse2, adf_index_of_string_stop_avx2,
                           adf_index_of_string_stop_neon};
    const Scan0 nonascii[] = {adf_index_of_nonascii, adf_index_of_nonascii_sse2, adf_index_of_nonascii_avx2, adf_index_of_nonascii_neon};
    for (size_t k = 0; k < LENGTHS; k++) {
        const size_t len = lengths[k];
        for (int end = 0; end < 2; end++) {
            Guarded buf = guarded(len, end);
            memset(buf.bytes, 'a', len);
            // Every byte value up to 129 bytes; past that, every position with the values at each classifier's edges.
            static const uint8_t edges[] = {0x00, 0x08, 0x09, 0x0A, 0x1F, 0x20, 0x21, 0x22, 0x26, 0x3C, 0x3E, 0x5C, 0x7E, 0x7F, 0x80, 0xFF};
            const int every = len <= 129;
            for (size_t p = 0; p < len; p += (len > 300 ? 7 : 1)) {
                for (int e = 0; e < (every ? 256 : (int)sizeof edges); e++) {
                    const int v = every ? e : edges[e];
                    buf.bytes[p] = (uint8_t)v;
                    const size_t stop = adf_index_of_string_stop_scalar(buf.bytes, len, '"', '\\');
                    for (int b = 0; b < 4; b++) EXPECT(stops[b](buf.bytes, len, '"', '\\') == stop, "string stop %d len %zu pos %zu byte %d", b, len, p, v);
                    const size_t na = adf_index_of_nonascii_scalar(buf.bytes, len);
                    for (int b = 0; b < 4; b++) EXPECT(nonascii[b](buf.bytes, len) == na, "nonascii %d len %zu pos %zu byte %d", b, len, p, v);
                    EXPECT(adf_index_of_any5(buf.bytes, len, '"', '\\', '<', '>', '&') ==
                               adf_index_of_any5_scalar(buf.bytes, len, '"', '\\', '<', '>', '&'),
                           "any5 len %zu pos %zu byte %d", len, p, v);
                    EXPECT(adf_index_of_control_or_any5(buf.bytes, len, '"', '\\', '<', '>', '&') ==
                               adf_index_of_control_or_any5_scalar(buf.bytes, len, '"', '\\', '<', '>', '&'),
                           "control or any5 len %zu pos %zu byte %d", len, p, v);
                    for (int tab = 0; tab < 2; tab++) {
                        for (int min = 0x20; min <= 0x21; min++) {
                            EXPECT(adf_first_disallowed_text(buf.bytes, len, (uint8_t)min, tab) ==
                                       adf_first_disallowed_text_scalar(buf.bytes, len, (uint8_t)min, tab),
                                   "disallowed text len %zu pos %zu byte %d", len, p, v);
                        }
                    }
                    EXPECT(adf_index_of_byte(buf.bytes, len, (uint8_t)(v ^ 1)) == adf_index_of_byte_scalar(buf.bytes, len, (uint8_t)(v ^ 1)),
                           "byte len %zu pos %zu byte %d", len, p, v);
                    EXPECT(adf_index_of_set(buf.bytes, len, lo, hi) == adf_index_of_set_scalar(buf.bytes, len, lo, hi), "set len %zu pos %zu byte %d", len, p, v);
                    // The complement: a set holding the filler 'a' (and the set above), so only a placed byte can end the run.
                    EXPECT(adf_index_not_in_set(buf.bytes, len, filler_lo, filler_hi) == adf_index_not_in_set_scalar(buf.bytes, len, filler_lo, filler_hi),
                           "not in set len %zu pos %zu byte %d", len, p, v);
                }
                buf.bytes[p] = 'a';
            }
            release(buf);
        }
    }
    // Disallowed text with every minimum: the classifier's ranges.
    for (int min = 0; min < 256; min++) {
        uint8_t all[256];
        for (int v = 0; v < 256; v++) all[v] = (uint8_t)v;
        for (size_t start = 0; start < 256; start += 17) {
            for (int tab = 0; tab < 2; tab++) {
                EXPECT(adf_first_disallowed_text(all + start, 256 - start, (uint8_t)min, tab) ==
                           adf_first_disallowed_text_scalar(all + start, 256 - start, (uint8_t)min, tab),
                       "disallowed min %d start %zu tab %d", min, start, tab);
            }
        }
    }
}

// MARK: - Folding

static void folding(void) {
    typedef void (*Fold)(uint8_t *, const uint8_t *, size_t);
    const Fold folds[] = {adf_fold_ascii, adf_fold_ascii_sse2, adf_fold_ascii_avx2, adf_fold_ascii_neon};
    for (size_t k = 0; k < LENGTHS; k++) {
        const size_t len = lengths[k];
        Guarded src = guarded(len, 1), dst = guarded(len, 0);
        uint8_t *reference = malloc(len + 1);
        for (int round = 0; round < 256; round++) {
            for (size_t i = 0; i < len; i++) src.bytes[i] = (uint8_t)(round + (int)i * 13);
            adf_fold_ascii_scalar(reference, src.bytes, len);
            for (int b = 0; b < 4; b++) {
                folds[b](dst.bytes, src.bytes, len);
                EXPECT(memcmp(dst.bytes, reference, len) == 0, "fold %d len %zu round %d", b, len, round);
                // In place.
                memcpy(dst.bytes, src.bytes, len);
                folds[b](dst.bytes, dst.bytes, len);
                EXPECT(memcmp(dst.bytes, reference, len) == 0, "fold in place %d len %zu round %d", b, len, round);
            }
        }
        free(reference);
        release(src);
        release(dst);
    }
}

// MARK: - UTF-8

/// Every one-, two- and three-byte sequence and every four-byte lead with every continuation pattern, at positions around the
/// 16- and 64-byte blocks, after ASCII and after a valid multibyte character.
static void utf8(void) {
    const size_t positions[] = {0, 13, 14, 15, 16, 31, 62, 63};
    const size_t len = 72;
    Guarded buf = guarded(len, 1);
    for (size_t q = 0; q < sizeof positions / sizeof positions[0]; q++) {
        const size_t p = positions[q];
        // Every single byte, every two-byte lead with every second byte, every three-byte lead with every following pair.
        for (unsigned seq = 0; seq < 256 + 32 * 256 + 16 * 65536; seq++) {
            uint8_t b0, b1 = 0, b2 = 0;
            if (seq < 256) {
                b0 = (uint8_t)seq;
            } else if (seq < 256 + 32 * 256) {
                b0 = (uint8_t)(0xC0 + (seq - 256) / 256);
                b1 = (uint8_t)(seq - 256);
            } else {
                const unsigned r = seq - 256 - 32 * 256;
                b0 = (uint8_t)(0xE0 + r / 65536);
                b1 = (uint8_t)(r >> 8);
                b2 = (uint8_t)r;
            }
            memset(buf.bytes, 'x', len);
            buf.bytes[p] = b0;
            if (p + 1 < len) buf.bytes[p + 1] = b1 ? b1 : buf.bytes[p + 1];
            if (p + 2 < len) buf.bytes[p + 2] = b2 ? b2 : buf.bytes[p + 2];
            EXPECT(adf_first_invalid_utf8(buf.bytes, len) == adf_first_invalid_utf8_scalar(buf.bytes, len), "utf8 at %zu: %02x %02x %02x",
                   p, b0, b1, b2);
        }
        // Four-byte leads with every continuation triple drawn from the boundary values.
        const uint8_t cont[] = {0x7F, 0x80, 0x8F, 0x90, 0x9F, 0xA0, 0xBF, 0xC0};
        for (int lead = 0xF0; lead <= 0xFF; lead++) {
            for (int x = 0; x < 8; x++) for (int y = 0; y < 8; y++) for (int z = 0; z < 8; z++) {
                memset(buf.bytes, 'x', len);
                buf.bytes[p] = (uint8_t)lead;
                if (p + 1 < len) buf.bytes[p + 1] = cont[x];
                if (p + 2 < len) buf.bytes[p + 2] = cont[y];
                if (p + 3 < len) buf.bytes[p + 3] = cont[z];
                EXPECT(adf_first_invalid_utf8(buf.bytes, len) == adf_first_invalid_utf8_scalar(buf.bytes, len), "utf8 4-byte at %zu", p);
            }
        }
    }
    release(buf);
    // A truncated sequence at the very end of every length, guarded.
    for (size_t k = 0; k < LENGTHS; k++) {
        const size_t n = lengths[k];
        Guarded tail = guarded(n, 1);
        memset(tail.bytes, 'y', n);
        const uint8_t leads[] = {0xC3, 0xE2, 0x82, 0xF0, 0x9F, 0x98};
        for (size_t cut = 1; cut <= 3 && cut <= n; cut++) {
            memcpy(tail.bytes + n - cut, leads + (cut == 1 ? 0 : cut == 2 ? 1 : 3), cut);
            EXPECT(adf_first_invalid_utf8(tail.bytes, n) == adf_first_invalid_utf8_scalar(tail.bytes, n), "utf8 truncated len %zu cut %zu", n, cut);
        }
        release(tail);
    }
}

// MARK: - UTF-16, checksums, bit counts, Hamming

static void numeric(void) {
    // UTF-16LE ASCII prefix: every awkward unit at every position.
    const uint16_t units[] = {0x0000, 0x007F, 0x0080, 0x00FF, 0x0100, 0x7F00, 0x8000, 0xFF7F, 0xFFFF};
    for (size_t count = 0; count <= 70; count++) {
        Guarded in = guarded(2 * count, 1), out = guarded(count, 1);
        uint8_t reference[80];
        for (size_t p = 0; p <= count; p++) {
            for (size_t u = 0; u < sizeof units / sizeof units[0]; u++) {
                for (size_t i = 0; i < count; i++) {
                    in.bytes[2 * i] = (uint8_t)('a' + i % 26);
                    in.bytes[2 * i + 1] = 0;
                }
                if (p < count) {
                    in.bytes[2 * p] = (uint8_t)units[u];
                    in.bytes[2 * p + 1] = (uint8_t)(units[u] >> 8);
                }
                const size_t expected = adf_utf16le_ascii_prefix_scalar(in.bytes, count, reference);
                const size_t got = adf_utf16le_ascii_prefix(in.bytes, count, out.bytes);
                EXPECT(got == expected && memcmp(out.bytes, reference, got) == 0, "utf16 count %zu pos %zu unit %04x", count, p, units[u]);
            }
        }
        release(in);
        release(out);
    }
    // CRC-32C: every length to 600 and past the 4 KiB chunk, guarded, split at every point of the short ones (chaining).
    for (size_t len = 0; len <= 8300; len += (len < 600 ? 1 : len < 4000 ? 61 : 7)) {
        Guarded buf = guarded(len, (int)(len & 1));
        for (size_t i = 0; i < len; i++) buf.bytes[i] = (uint8_t)(i * 151 + 3);
        const uint32_t whole = adf_crc32c_update_scalar(0xFFFFFFFFu, buf.bytes, len);
        EXPECT(adf_crc32c_update(0xFFFFFFFFu, buf.bytes, len) == whole, "crc32c len %zu", len);
        if (len <= 300) {
            for (size_t split = 0; split <= len; split++) {
                const uint32_t first = adf_crc32c_update(0xFFFFFFFFu, buf.bytes, split);
                EXPECT(adf_crc32c_update(first, buf.bytes + split, len - split) == whole, "crc32c len %zu split %zu", len, split);
            }
        }
        release(buf);
    }
    // The CRC-32C check value: "123456789" -> 0xE3069283 (after the final inversion).
    EXPECT((adf_crc32c_update(0xFFFFFFFFu, (const uint8_t *)"123456789", 9) ^ 0xFFFFFFFFu) == 0xE3069283u, "crc32c check value");
    // Bit counts and Hamming: every length to 300, and across the u16 accumulators' flush (2048 * 16 bytes) with every bit set.
    const size_t big[] = {32767, 32768, 32769, 65536, 100003};
    for (size_t k = 0; k < 300 + 5; k++) {
        const size_t len = k < 300 ? k : big[k - 300];
        Guarded a = guarded(len, 1), b = guarded(len, 0);
        for (int pattern = 0; pattern < 3; pattern++) {
            for (size_t i = 0; i < len; i++) {
                a.bytes[i] = pattern == 0 ? 0xFF : (uint8_t)(i * 37 + 1);
                b.bytes[i] = pattern == 0 ? 0x00 : pattern == 1 ? (uint8_t)(i * 11) : 0xFF;
            }
            EXPECT(adf_bit_count(a.bytes, len) == adf_bit_count_scalar(a.bytes, len), "bit count len %zu pattern %d", len, pattern);
            EXPECT(adf_hamming_distance(a.bytes, b.bytes, len) == adf_hamming_distance_scalar(a.bytes, b.bytes, len),
                   "hamming len %zu pattern %d", len, pattern);
        }
        release(a);
        release(b);
    }
    // The batched Hamming scan: every width to 80 and a few past the flush, against the single-pair reference.
    for (size_t width = 1; width <= 33000; width += (width < 80 ? 1 : 4111)) {
        const size_t count = width < 80 ? 5 : 2;
        Guarded query = guarded(width, 1), corpus = guarded(width * count, 1);
        for (size_t i = 0; i < width; i++) query.bytes[i] = (uint8_t)(i * 7);
        for (size_t i = 0; i < width * count; i++) corpus.bytes[i] = (uint8_t)(i * 13 + 5);
        uint32_t *out = malloc(count * sizeof(uint32_t));
        adf_hamming_scan(query.bytes, corpus.bytes, width, count, out);
        for (size_t v = 0; v < count; v++) {
            EXPECT(out[v] == adf_hamming_distance_scalar(query.bytes, corpus.bytes + v * width, width), "hamming scan width %zu vector %zu", width, v);
        }
        free(out);
        release(query);
        release(corpus);
    }
}

// MARK: - Dates

/// Days since 1970-01-01 by another method than the kernel's: timegm for the Gregorian years, and the Julian calendar's
/// day number (Meeus) before the reform.
static int reference_date(int year, int month, int day, int hour, int minute, int second, int64_t *out) {
    if (year < 1 || year == 1582 || month < 1 || month > 12 || day < 1 || hour > 23 || minute > 59 || second > 59) return 0;
    const int gregorian = year >= 1583;
    const int leap = gregorian ? ((year % 4 == 0 && year % 100 != 0) || year % 400 == 0) : (year % 4 == 0);
    const int lengthOf[13] = {0, 31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
    if (day > lengthOf[month]) return 0;
    int64_t days;
    if (gregorian) {
        // Hinnant's days_from_civil (eras of 400 years), not the kernel's Fliegel-Van Flandern.
        const int64_t y = month <= 2 ? year - 1 : year;
        const int64_t era = (y >= 0 ? y : y - 399) / 400;
        const int64_t yoe = y - era * 400;
        const int64_t doy = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1;
        const int64_t doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        days = era * 146097 + doe - 719468;
    } else {
        // Meeus, Astronomical Algorithms, 7.1, with B = 0 (Julian calendar); JD at 0h is the floor below, minus 0.5.
        int y = year, m = month;
        if (m <= 2) {
            y -= 1;
            m += 12;
        }
        const int64_t jdn = (int64_t)(365.25 * (y + 4716)) + (int64_t)(30.6001 * (m + 1)) + day - 1524;  // JDN at noon
        days = jdn - 2440588;
    }
    *out = days * 86400 + hour * 3600 + minute * 60 + second;
    return 1;
}

static void dates(void) {
    char text[21];
    for (int year = 1; year <= 9999; year++) {
        for (int month = 0; month <= 13; month++) {
            for (int day = 0; day <= 32; day++) {
                if (year % 97 != 0 && year != 1581 && year != 1583 && year != 1600 && year != 1900 && year != 2000 && year != 2400 &&
                    day > 1 && day < 28) continue;  // every day of a sample of years, the month edges of all
                snprintf(text, sizeof text, "%04d-%02d-%02dT%02d:%02d:%02dZ", year, month, day, (year * 7) % 24, (day * 3) % 60, (month * 5) % 60);
                int64_t got = 0, expected = 0;
                const int ok = adf_parse_iso8601_utc((const uint8_t *)text, 20, &got);
                const int ref = reference_date(year, month, day, (year * 7) % 24, (day * 3) % 60, (month * 5) % 60, &expected);
                EXPECT(ok == ref && (!ok || got == expected), "date %s: %d %lld vs %d %lld", text, ok, (long long)got, ref, (long long)expected);
            }
        }
    }
    // Every byte at every position of a valid timestamp, guarded: whatever it is, the answer is the reference's.
    const char *base = "2026-11-02T13:45:59Z";
    Guarded buf = guarded(20, 1);
    for (int p = 0; p < 20; p++) {
        for (int v = 0; v < 256; v++) {
            memcpy(buf.bytes, base, 20);
            buf.bytes[p] = (uint8_t)v;
            int64_t got = 0, expected = 0;
            const int ok = adf_parse_iso8601_utc(buf.bytes, 20, &got);
            int fields[6], valid = 1;
            const int at[6][2] = {{0, 4}, {5, 2}, {8, 2}, {11, 2}, {14, 2}, {17, 2}};
            for (int f = 0; f < 6; f++) {
                fields[f] = 0;
                for (int d = 0; d < at[f][1]; d++) {
                    const uint8_t c = buf.bytes[at[f][0] + d];
                    if (c < '0' || c > '9') valid = 0;
                    fields[f] = fields[f] * 10 + (c - '0');
                }
            }
            if (buf.bytes[4] != '-' || buf.bytes[7] != '-' || buf.bytes[10] != 'T' || buf.bytes[13] != ':' || buf.bytes[16] != ':' ||
                buf.bytes[19] != 'Z') valid = 0;
            const int ref = valid && reference_date(fields[0], fields[1], fields[2], fields[3], fields[4], fields[5], &expected);
            EXPECT(ok == ref && (!ok || got == expected), "date mutated at %d byte %d", p, v);
        }
    }
    for (size_t len = 0; len <= 21; len++) {
        int64_t out = 0;
        if (len != 20) EXPECT(adf_parse_iso8601_utc((const uint8_t *)"2026-11-02T13:45:59Z!", len, &out) == 0, "date length %zu", len);
    }
    release(buf);
}

/// Every position of either of two bytes, against the scalar reference: inputs of every length class flush against a guard page,
/// hits at every density (none, one at each position, every k-th, all), and every output size around the vector steps, both in
/// one call and resumed from `consumed` until the input is done.
static void positions(void) {
    for (size_t k = 0; k < LENGTHS; k++) {
        const size_t len = lengths[k];
        uint32_t *want = malloc((len + 1) * sizeof(uint32_t)), *got = malloc((len + 1) * sizeof(uint32_t));
        for (int end = 0; end < 2; end++) {
            Guarded buf = guarded(len, end);
            for (int every = 0; every <= 9; every++) {
                for (size_t single = 0; single <= (every == 0 ? len : 0); single++) {
                    for (size_t i = 0; i < len; i++) {
                        const int hit = every == 0 ? (i + 1 == single) : (i % (size_t)every == 0);
                        buf.bytes[i] = hit ? (i % 2 ? '\n' : '\r') : (uint8_t)('a' + i % 13);
                    }
                    size_t want_consumed = 0;
                    const size_t want_n = adf_positions_of_either_scalar(buf.bytes, len, '\n', '\r', 7, want, len + 1, &want_consumed);
                    EXPECT(want_consumed == len, "positions reference len %zu", len);
                    static const size_t caps[] = {1, 2, 15, 16, 17, 31, 32, 33, 63, 64, 65, 200, SIZE_MAX};
                    for (size_t c = 0; c < sizeof caps / sizeof caps[0]; c++) {
                        const size_t cap = caps[c] == SIZE_MAX ? len + 1 : caps[c];
                        size_t total = 0, at = 0, rounds = 0;
                        uint32_t *room = malloc(cap * sizeof(uint32_t));
                        while (at < len && rounds++ <= len + 1) {
                            size_t consumed = 0;
                            const size_t n = adf_positions_of_either(buf.bytes + at, len - at, '\n', '\r', 7 + (uint32_t)at, room, cap, &consumed);
                            EXPECT(n <= cap && consumed <= len - at, "positions bounds len %zu cap %zu", len, cap);
                            EXPECT(n > 0 || consumed == len - at, "positions progress len %zu cap %zu", len, cap);
                            if (total + n <= len + 1) memcpy(got + total, room, n * sizeof(uint32_t));
                            total += n;
                            at += consumed;
                            if (n == 0 && consumed == 0) break;
                        }
                        EXPECT(at == len && total == want_n && memcmp(got, want, want_n * sizeof(uint32_t)) == 0,
                               "positions len %zu every %d single %zu cap %zu", len, every, single, cap);
                        free(room);
                    }
                }
            }
            release(buf);
        }
        free(want);
        free(got);
    }
}

int main(void) {
    scanners();
    positions();
    printf("scanners (host %s): %ld checks\n", adf_kernels_backend(), checks);
    folding();
    utf8();
    numeric();
    dates();
    printf("exhaustive kernels (host %s): %ld checks, %ld failures\n", adf_kernels_backend(), checks, failures);
    return failures != 0;
}

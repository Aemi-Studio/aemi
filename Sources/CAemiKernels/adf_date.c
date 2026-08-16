//
//  adf_date.c
//  CAemiKernels
//
//  Foundation-free date-string parsers for the AD* family, consolidated here so ADJSON (ISO 8601) and
//  HTTP / ADServe (HTTP-date) share one implementation. These are the "kernel" form of the date parsers:
//  they read raw bytes (so a caller can parse straight out of a tape / socket buffer with no intermediate
//  String) and return seconds since the Unix epoch, or 0 to signal "defer to the platform parser" for
//  any shape/range they intentionally don't cover — the caller (which has Foundation) then falls back,
//  preserving byte-identical behavior.
//
//  These are SCALAR by design. Each parse is a fixed ~20-30 byte string of a handful of integer ops;
//  a per-call SIMD dispatch (feature check + vector setup + horizontal reduction) costs more than the
//  scalar arithmetic it would replace, exactly as the single-pair Hamming kernel measured. The compiler
//  lowers the integer math below to tight arm64 / x86-64 code with no help needed. The calendar
//  arithmetic (Fliegel-Van Flandern Julian Day Number, with the 1582 Gregorian reform) is pure integer
//  and identical on every arch.
//

#include "include/CAemiKernels.h"

// Julian Day Number for a proleptic date, then shifted to days since 1970-01-01 (JDN 2440588). The
// Gregorian branch (on/after the 1582-10-15 reform) applies the century leap-day correction; the Julian
// branch (before it) does not. At the boundary the two are continuous (1582-10-04 Julian and 1582-10-15
// Gregorian are consecutive). `gregorian` selects the branch.
static int64_t adf_days_from_civil(int year, int month, int day, int gregorian) {
    int a = (14 - month) / 12;
    int64_t y = (int64_t)year + 4800 - a;
    int m = month + 12 * a - 3;
    int64_t common = (int64_t)day + (153 * m + 2) / 5 + 365 * y + y / 4;
    int64_t jdn = gregorian ? common - y / 100 + y / 400 - 32045 : common - 32083;
    return jdn - 2440588;
}

int adf_parse_iso8601_utc(const uint8_t *buf, size_t len, int64_t *out) {
    // Canonical UTC form only: "YYYY-MM-DDTHH:MM:SSZ", exactly 20 bytes. Anything else defers.
    if (len != 20) {
        return 0;
    }
    if (buf[4] != '-' || buf[7] != '-' || buf[10] != 'T' || buf[13] != ':' || buf[16] != ':'
        || buf[19] != 'Z') {
        return 0;
    }
    // The 14 digit positions; a non-digit anywhere defers.
    static const int digit_pos[14] = {0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18};
    for (int i = 0; i < 14; i++) {
        uint8_t c = buf[digit_pos[i]];
        if (c < '0' || c > '9') {
            return 0;
        }
    }
    int year = (buf[0] - '0') * 1000 + (buf[1] - '0') * 100 + (buf[2] - '0') * 10 + (buf[3] - '0');
    int month = (buf[5] - '0') * 10 + (buf[6] - '0');
    int day = (buf[8] - '0') * 10 + (buf[9] - '0');
    int hour = (buf[11] - '0') * 10 + (buf[12] - '0');
    int minute = (buf[14] - '0') * 10 + (buf[15] - '0');
    int second = (buf[17] - '0') * 10 + (buf[18] - '0');
    if (month < 1 || month > 12 || day < 1 || hour > 23 || minute > 59 || second > 59) {
        return 0;
    }
    // Foundation follows the Julian calendar before the 1582 Gregorian reform; the reform year 1582
    // (with its skipped 5-14 October) and years < 1 defer to Foundation to avoid the discontinuity.
    if (year < 1 || year == 1582) {
        return 0;
    }
    int gregorian = year >= 1583;
    int leap = gregorian ? ((year % 4 == 0 && year % 100 != 0) || year % 400 == 0) : (year % 4 == 0);
    int days_in_month;
    switch (month) {
        case 2: days_in_month = leap ? 29 : 28; break;
        case 4: case 6: case 9: case 11: days_in_month = 30; break;
        default: days_in_month = 31; break;
    }
    if (day > days_in_month) {
        return 0;
    }
    int64_t days = adf_days_from_civil(year, month, day, gregorian);
    *out = days * 86400 + (int64_t)(hour * 3600 + minute * 60 + second);
    return 1;
}

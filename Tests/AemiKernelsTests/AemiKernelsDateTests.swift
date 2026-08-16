import AemiKernels
import Testing

/// The `adf_parse_iso8601_utc` kernel, checked against independently-known Unix timestamps (not a
/// self-referential formula) and its defer contract. The full differential parity against Foundation's
/// `.iso8601` lives in ADJSON's `ISO8601FastTests`; this pins the kernel's arithmetic in AemiFoundation.
struct AemiKernelsDateTests {
    private func parse(_ s: String) -> Int64? {
        var s = s
        return s.withUTF8 { b in
            guard let base = b.baseAddress else { return nil }
            return AemiKernels.parseISO8601UTCSeconds(base, count: b.count)
        }
    }

    @Test func parsesCanonicalAnchors() {
        #expect(parse("1970-01-01T00:00:00Z") == 0)
        #expect(parse("1969-12-31T23:59:59Z") == -1)
        #expect(parse("2000-01-01T00:00:00Z") == 946_684_800)
        #expect(parse("2020-09-13T12:26:40Z") == 1_600_000_000)
        #expect(parse("2038-01-19T03:14:07Z") == 2_147_483_647)  // Y2038 boundary
        #expect(parse("2020-02-29T00:00:00Z") == 1_582_934_400)  // Gregorian leap day
    }

    @Test func handlesBothCalendarEras() {
        // Julian (pre-1583) parses too: 1000-01-01 Julian has JDN 2_086_308 ⇒ days since 1970-01-01 are
        // 2_086_308 − 2_440_588 = −354_280.
        #expect(parse("1000-01-01T00:00:00Z") == Int64(-354_280) * 86_400)
        #expect(parse("1581-12-31T23:59:59Z") != nil)  // last fully-Julian year: fast path engaged
    }

    @Test func defersNonCanonicalAndInvalid() {
        // Any non-canonical shape, out-of-range field, the reform year, or year < 1 → nil (caller falls
        // back to the platform parser, keeping the pair byte-identical).
        let deferred = [
            "2020-01-01T00:00:00",  // missing Z
            "2020-01-01T00:00:00.5Z",  // fractional seconds
            "2020-01-01T00:00:00+00:00",  // numeric offset
            "2020-13-01T00:00:00Z", "2020-00-01T00:00:00Z", "2020-01-32T00:00:00Z",
            "2020-01-01T24:00:00Z", "2020-01-01T00:60:00Z", "2020-01-01T00:00:60Z",
            "2019-02-29T00:00:00Z",  // Feb 29 in a non-leap year
            "1582-06-15T00:00:00Z",  // Gregorian-reform year
            "0000-01-01T00:00:00Z",  // year < 1
            "2020-1-1T0:0:0Z", "not-a-date-here-xxxx", ""
        ]
        for s in deferred {
            #expect(parse(s) == nil, "should defer: \(s)")
        }
    }
}

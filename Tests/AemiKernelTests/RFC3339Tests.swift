import AemiKernels
import Testing

@testable import AemiKernel

/// RFC 3339 and its configuration-format variations (ADR 0031). The calendar is checked against AemiKernels' C date kernel
/// (itself checked against Hinnant's eras, ADR 0027) for every day of a span of years; the grammar against hand cases.
struct RFC3339Tests {
    @Test func `every day of 1890 to 2110 counts the same seconds as the C kernel`() {
        var checked = 0
        for year in 1890 ... 2110 {
            for month in 1 ... 12 {
                for day in 1 ... RFC3339DateTime.days(inMonth: month, year: year) {
                    let text =
                        RFC3339DateTime.pad(year, 4) + "-" + RFC3339DateTime.pad(month, 2) + "-"
                        + RFC3339DateTime.pad(day, 2)
                        + "T13:07:59Z"
                    let parsed = RFC3339DateTime(parsing: text)
                    let bytes = Array(text.utf8)
                    let kernel = bytes.withUnsafeBufferPointer {
                        AemiKernels.parseISO8601UTCSeconds($0.baseAddress!, count: 20)
                    }
                    #expect(parsed?.unixSeconds == kernel, "\(text)")
                    checked += 1
                }
            }
        }
        #expect(checked == 221 * 365 + 53)  // 53 leap years: 1892 to 2108, less 1900 and 2100
    }

    @Test func `strict RFC 3339 accepts full date-times only, with t, z and offsets`() {
        for text in [
            "1985-04-12T23:20:50.52Z", "1996-12-19T16:39:57-08:00", "1990-12-31t23:59:60z",
            "1937-01-01T12:00:27.87+00:20"
        ] {
            #expect(RFC3339DateTime(parsing: text) != nil, "\(text)")
        }
        for text in [
            "1985-04-12", "23:20:50", "1985-04-12 23:20:50Z", "1985-04-12T23:20Z", "1985-04-12T23:20:50",
            "1985-04-12T23:20:50.Z",
            "1985-02-29T00:00:00Z", "1985-13-01T00:00:00Z", "1985-04-12T24:00:00Z", "1985-04-12T23:60:00Z",
            "1985-04-12T23:20:61Z",
            "1985-04-12T23:20:50+24:00", "1985-04-12T23:20:50+0100", "85-04-12T23:20:50Z", "1985-04-12T23:20:50Zx"
        ] {
            #expect(RFC3339DateTime(parsing: text) == nil, "\(text)")
        }
        #expect(RFC3339DateTime(parsing: "2000-02-29T00:00:00Z") != nil)
        #expect(RFC3339DateTime(parsing: "1900-02-29T00:00:00Z") == nil)
    }

    @Test func `TOML's local forms, the space and optional seconds, and the canonical text`() {
        let cases: [(String, RFC3339DateTime.Syntax, String?)] = [
            ("1979-05-27", .toml10, "1979-05-27"), ("07:32:00", .toml10, "07:32:00"),
            ("1979-05-27 07:32:00.999999", .toml10, "1979-05-27T07:32:00.999999"),
            ("1979-05-27T00:32:00.1234567891-07:00", .toml10, "1979-05-27T00:32:00.123456789-07:00"),
            ("1979-05-27 07:32Z", .toml11, "1979-05-27T07:32:00Z"), ("13:37", .toml11, "13:37:00"),
            ("13:37", .toml10, nil),
            ("1979-05-27 07:32:00", .rfc3339, nil), ("1979-05-27T07:32:00", .rfc3339, nil)
        ]
        for (text, syntax, expected) in cases {
            #expect(RFC3339DateTime(parsing: text, syntax: syntax)?.description == expected, "\(text)")
        }
        #expect(RFC3339DateTime(parsing: "1979-05-27T07:32:00", syntax: .toml10)?.unixSeconds == nil)
        #expect(RFC3339DateTime(parsing: "1970-01-01T01:00:00+01:00")?.unixSeconds == 0)
    }
}

//
//  HTTPDateParser.swift
//  AemiKernel
//
//  RFC 9110 §5.6.7 HTTP-date parsing, consolidated here so `HTTPCore` and `ADServeCore` share one
//  implementation instead of each carrying its own. Foundation-free (Howard Hinnant's days-from-civil
//  arithmetic, no `Calendar`); accepts the preferred IMF-fixdate plus the two obsolete forms a recipient
//  must still accept. Formatting stays with each server (emitting IMF-fixdate is trivial); this is the
//  parse half both need. Iterative; never traps on hostile input.
//

/// Parses an RFC 9110 §5.6.7 HTTP-date to whole seconds since the Unix epoch. A caseless enum used as a
/// namespace — the idiomatic Swift home for this small family of free functions.
public enum HTTPDateParser {
    private static let months = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"
    ]

    /// Seconds since the Unix epoch (UTC) for an HTTP-date, or `nil` if malformed. Accepts the preferred
    /// IMF-fixdate (`Sun, 06 Nov 1994 08:49:37 GMT`) and the two obsolete forms a recipient must still
    /// accept — rfc850 (`Sunday, 06-Nov-94 08:49:37 GMT`) and asctime (`Sun Nov  6 08:49:37 1994`).
    /// Lenient tokenizing (any run of SP / HTAB / comma separates fields, empty fields collapse).
    public static func parse(_ value: String) -> Int? {
        let tokens = value.split { $0 == " " || $0 == "\t" || $0 == "," }
        switch tokens.count {
            case 6: return parseIMFFixdate(tokens)
            case 5: return parseAsctime(tokens)
            case 4: return parseRFC850(tokens)
            default: return nil
        }
    }

    /// IMF-fixdate: `Sun, 06 Nov 1994 08:49:37 GMT` → [Sun, 06, Nov, 1994, 08:49:37, GMT].
    private static func parseIMFFixdate(_ tokens: [Substring]) -> Int? {
        guard tokens[5] == "GMT", let day = Int(tokens[1]), let month = monthIndex(tokens[2]),
            let year = Int(tokens[3])
        else {
            return nil
        }
        return epoch(year: year, month: month, day: day, time: tokens[4])
    }

    /// asctime: `Sun Nov  6 08:49:37 1994` → [Sun, Nov, 6, 08:49:37, 1994].
    private static func parseAsctime(_ tokens: [Substring]) -> Int? {
        guard let month = monthIndex(tokens[1]), let day = Int(tokens[2]), let year = Int(tokens[4])
        else {
            return nil
        }
        return epoch(year: year, month: month, day: day, time: tokens[3])
    }

    /// rfc850: `Sunday, 06-Nov-94 08:49:37 GMT` → [Sunday, 06-Nov-94, 08:49:37, GMT].
    private static func parseRFC850(_ tokens: [Substring]) -> Int? {
        guard tokens[3] == "GMT" else {
            return nil
        }
        let parts = tokens[1].split(separator: "-")
        guard parts.count == 3, let day = Int(parts[0]), let month = monthIndex(parts[1]),
            let shortYear = Int(parts[2])
        else {
            return nil
        }
        // A 2-digit year pivoted at 70 (a far-future value is read as the recent past, RFC 6265 §5.1.1).
        let year = shortYear < 70 ? 2_000 + shortYear : 1_900 + shortYear
        return epoch(year: year, month: month, day: day, time: tokens[2])
    }

    /// Seconds since the epoch for a calendar date and an `HH:MM:SS` token, or `nil` if out of range.
    private static func epoch(year: Int, month: Int, day: Int, time: Substring) -> Int? {
        let parts = time.split(separator: ":")
        guard parts.count == 3, let hour = Int(parts[0]), let minute = Int(parts[1]),
            let second = Int(parts[2]),
            (1 ... 12).contains(month), (1 ... 31).contains(day),
            (0 ... 23).contains(hour), (0 ... 59).contains(minute), (0 ... 60).contains(second)
        else {
            return nil
        }
        return daysFromCivil(year: year, month: month, day: day) * 86_400
            + hour * 3_600 + minute * 60 + second
    }

    /// Days since 1970-01-01 for a calendar date — Howard Hinnant's days-from-civil (proleptic Gregorian).
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let shiftedYear = month <= 2 ? year - 1 : year
        let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
        let yearOfEra = shiftedYear - era * 400
        let dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    /// The 1-based month number for a three-letter English month name, or `nil` if unrecognized.
    private static func monthIndex(_ name: some StringProtocol) -> Int? {
        months.firstIndex(of: String(name)).map { $0 + 1 }
    }
}

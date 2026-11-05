/// An RFC 3339 date, time or date-time, and the variations configuration formats allow (ADR 0031): TOML's local forms, a space
/// for the `T`, lowercase `t` and `z`, and (TOML 1.1) times without seconds. JSON Schema's `date-time`, `date` and `time` are
/// ``Syntax/rfc3339``. Fields a kind does not have are zero; fractional seconds are truncated (not rounded) to nanoseconds, as
/// TOML requires of extra precision. Ranges are checked: the month's last day in a leap year, hours, minutes, seconds to 60
/// (a leap second), offsets within a day.
public struct RFC3339DateTime: Sendable, Hashable, CustomStringConvertible {
    public enum Kind: Sendable, Hashable {
        case offsetDateTime
        case localDateTime
        case localDate
        case localTime
    }

    /// What a parse accepts beyond RFC 3339's full date-time.
    public struct Syntax: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        /// A date-time without an offset.
        public static let localDateTime = Self(rawValue: 1 << 0)
        /// A date alone.
        public static let localDate = Self(rawValue: 1 << 1)
        /// A time alone.
        public static let localTime = Self(rawValue: 1 << 2)
        /// A space between date and time (RFC 3339 §5.6's note).
        public static let spaceSeparator = Self(rawValue: 1 << 3)
        /// `HH:MM` without seconds.
        public static let optionalSeconds = Self(rawValue: 1 << 4)

        /// RFC 3339 `date-time`: `T` or `t`, `Z`, `z` or an offset, seconds required.
        public static let rfc3339: Self = []
        /// TOML 1.0: every local form and the space separator.
        public static let toml10: Self = [.localDateTime, .localDate, .localTime, .spaceSeparator]
        /// TOML 1.1: as 1.0, with seconds optional.
        public static let toml11: Self = [.toml10, .optionalSeconds]
    }

    public var kind: Kind
    public var year = 0
    public var month = 0
    public var day = 0
    public var hour = 0
    public var minute = 0
    public var second = 0
    public var nanosecond = 0
    /// Minutes east of UTC; nil unless ``kind`` is ``Kind/offsetDateTime``.
    public var offsetMinutes: Int?

    public init(kind: Kind) { self.kind = kind }

    /// The whole of `bytes` as one value of a kind `syntax` allows, or nil.
    public init?(parsing bytes: ArraySlice<UInt8>, syntax: Syntax = .rfc3339) {
        var reader = Reader(bytes: bytes)
        guard let value = reader.read(syntax), reader.index == bytes.endIndex else { return nil }
        self = value
    }

    /// As ``init(parsing:syntax:)-(ArraySlice<UInt8>,_)``.
    public init?(parsing text: String, syntax: Syntax = .rfc3339) {
        self.init(parsing: Array(text.utf8)[...], syntax: syntax)
    }

    public var hasDate: Bool { kind != .localTime }
    public var hasTime: Bool { kind != .localDate }

    /// Seconds since 1970-01-01T00:00:00Z, for an offset date-time (proleptic Gregorian; a leap second counts as the next
    /// second's first instant would): nil for the local kinds, which name no instant.
    public var unixSeconds: Int64? {
        guard kind == .offsetDateTime, let offset = offsetMinutes else { return nil }
        // Howard Hinnant's days_from_civil.
        let y = Int64(month <= 2 ? year - 1 : year)
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let shiftedMonth = Int64(month > 2 ? month - 3 : month + 9)
        let dayOfYear = (153 * shiftedMonth + 2) / 5 + Int64(day) - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        let days = era * 146_097 + dayOfEra - 719_468
        return days * 86400 + Int64(hour * 3600 + minute * 60 + second) - Int64(offset) * 60
    }

    /// RFC 3339: `T` between date and time, seconds always, the fraction without trailing zeros, `Z` for a zero offset.
    public var description: String {
        var text = ""
        if hasDate { text += Self.pad(year, 4) + "-" + Self.pad(month, 2) + "-" + Self.pad(day, 2) }
        if hasDate, hasTime { text += "T" }
        if hasTime {
            text += Self.pad(hour, 2) + ":" + Self.pad(minute, 2) + ":" + Self.pad(second, 2)
            if nanosecond > 0 {
                var fraction = Self.pad(nanosecond, 9)
                while fraction.last == "0" { fraction.removeLast() }
                text += "." + fraction
            }
        }
        if let offset = offsetMinutes {
            text +=
                offset == 0
                ? "Z" : (offset < 0 ? "-" : "+") + Self.pad(abs(offset) / 60, 2) + ":" + Self.pad(abs(offset) % 60, 2)
        }
        return text
    }

    static func pad(_ value: Int, _ width: Int) -> String {
        let digits = String(value)
        return String(repeating: "0", count: Swift.max(0, width - digits.count)) + digits
    }

    public static func isLeapYear(_ year: Int) -> Bool { year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) }

    public static func days(inMonth month: Int, year: Int) -> Int {
        switch month {
            case 2: isLeapYear(year) ? 29 : 28
            case 4, 6, 9, 11: 30
            default: 31
        }
    }
}

extension RFC3339DateTime {
    struct Reader {
        let bytes: ArraySlice<UInt8>
        var index: Int

        init(bytes: ArraySlice<UInt8>) {
            self.bytes = bytes
            index = bytes.startIndex
        }

        var peek: UInt8? { index < bytes.endIndex ? bytes[index] : nil }

        mutating func take(_ byte: UInt8) -> Bool {
            guard peek == byte else { return false }
            index += 1
            return true
        }

        mutating func digits(_ count: Int) -> Int? {
            guard bytes.endIndex - index >= count else { return nil }
            var value = 0
            for _ in 0 ..< count {
                let digit = bytes[index] &- 0x30
                guard digit < 10 else { return nil }
                value = value * 10 + Int(digit)
                index += 1
            }
            return value
        }

        mutating func read(_ syntax: Syntax) -> RFC3339DateTime? {
            let start = bytes.startIndex
            // `HH:` is a time, `YYYY-` a date.
            if bytes.count >= 3, bytes[start + 2] == 0x3A {
                guard syntax.contains(.localTime) else { return nil }
                var value = RFC3339DateTime(kind: .localTime)
                return time(into: &value, syntax) ? value : nil
            }
            guard let year = digits(4), take(0x2D), let month = digits(2), take(0x2D), let day = digits(2),
                (1 ... 12).contains(month), (1 ... days(inMonth: month, year: year)).contains(day)
            else { return nil }
            var value = RFC3339DateTime(kind: .localDate)
            (value.year, value.month, value.day) = (year, month, day)
            guard let separator = peek else { return syntax.contains(.localDate) ? value : nil }
            guard separator == 0x54 || separator == 0x74 || (separator == 0x20 && syntax.contains(.spaceSeparator))
            else {
                return syntax.contains(.localDate) ? value : nil
            }
            index += 1
            value.kind = .localDateTime
            guard time(into: &value, syntax) else { return nil }
            if peek == nil { return syntax.contains(.localDateTime) ? value : nil }
            return offset(into: &value) ? value : nil
        }

        mutating func time(into value: inout RFC3339DateTime, _ syntax: Syntax) -> Bool {
            guard let hour = digits(2), take(0x3A), let minute = digits(2), hour < 24, minute < 60 else { return false }
            (value.hour, value.minute) = (hour, minute)
            guard take(0x3A) else { return syntax.contains(.optionalSeconds) }
            guard let second = digits(2), second <= 60 else { return false }
            value.second = second
            guard take(0x2E) else { return true }
            var places = 0
            while let byte = peek, byte &- 0x30 < 10 {
                if places < 9 { value.nanosecond = value.nanosecond * 10 + Int(byte - 0x30) }
                places += 1
                index += 1
            }
            guard places > 0 else { return false }
            for _ in Swift.min(places, 9) ..< 9 { value.nanosecond *= 10 }
            return true
        }

        mutating func offset(into value: inout RFC3339DateTime) -> Bool {
            value.kind = .offsetDateTime
            if take(0x5A) || take(0x7A) {
                value.offsetMinutes = 0
                return true
            }
            guard let sign = peek, sign == 0x2B || sign == 0x2D else { return false }
            index += 1
            guard let hours = digits(2), take(0x3A), let minutes = digits(2), hours < 24, minutes < 60 else {
                return false
            }
            value.offsetMinutes = (sign == 0x2D ? -1 : 1) * (hours * 60 + minutes)
            return true
        }
    }
}

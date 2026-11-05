/// A decimal number as written, read in one pass (ADR 0031): `[+|-] digits [. digits] [(e|E) [+|-] digits]`, with an optional digit
/// separator allowed only between two digits (TOML's `_`). What it is (sign, the first nineteen significant digits, the power of
/// ten, whether digits were dropped) and how it was written (digit counts, a leading zero, where it ends), so each grammar decides
/// what it accepts and ``DecimalFloat/double(_:in:separator:)-(_,[UInt8],_)`` turns it into the correctly rounded value.
///
/// Promoted from AemiJSON's `scanDecimal`, `scanPaddedDecimal` and `LongDecimal` (one implementation for JSON, TOML and YAML).
/// A number of up to nineteen digits (nearly all) is read in one tight pass that converts eight digits at a time with SWAR
/// (simdjson's `parse_eight_digits`); past nineteen, a zero-aware pass counts zeros only between significant digits, so
/// `0.000…01` and `1.000…0` keep the fast paths. Six words: the flags are bits, the counts 32-bit, so a literal is cheap to return.
public struct DecimalLiteral: Sendable, Equatable {
    /// The first nineteen significant digits, as an integer.
    public var significand: UInt64 = 0
    /// The power of ten `significand` is scaled by. Saturates far outside any finite `Double`.
    public var exponent = 0
    /// The index of the literal's first byte, and the index just after its last.
    public var start = 0
    public var end = 0
    @usableFromInline var integerCount: UInt32 = 0
    @usableFromInline var fractionCount: UInt32 = 0
    @usableFromInline var exponentCount: UInt32 = 0
    @usableFromInline var flags: UInt8 = 0

    @inlinable
    public init() {}

    @usableFromInline static let negativeFlag: UInt8 = 1
    @usableFromInline static let signedFlag: UInt8 = 2
    @usableFromInline static let truncatedFlag: UInt8 = 4
    @usableFromInline static let pointFlag: UInt8 = 8
    @usableFromInline static let exponentFlag: UInt8 = 16
    @usableFromInline static let leadingZeroFlag: UInt8 = 32

    @inlinable
    func has(_ flag: UInt8) -> Bool { flags & flag != 0 }

    @inlinable
    mutating func set(_ flag: UInt8, _ on: Bool) { flags = on ? flags | flag : flags & ~flag }

    public var negative: Bool {
        @inlinable get { has(Self.negativeFlag) }
        @inlinable set { set(Self.negativeFlag, newValue) }
    }

    /// A sign was written (`+` or `-`).
    public var signed: Bool {
        @inlinable get { has(Self.signedFlag) }
        @inlinable set { set(Self.signedFlag, newValue) }
    }

    /// Significant digits were dropped, or the exponent saturated: only the slow path rounds it exactly.
    public var truncated: Bool {
        @inlinable get { has(Self.truncatedFlag) }
        @inlinable set { set(Self.truncatedFlag, newValue) }
    }

    /// A point was written; ``fractionDigits`` says how many digits followed it.
    public var hasPoint: Bool {
        @inlinable get { has(Self.pointFlag) }
        @inlinable set { set(Self.pointFlag, newValue) }
    }

    /// An exponent was written; ``exponentDigits`` says how many digits it has.
    public var hasExponent: Bool {
        @inlinable get { has(Self.exponentFlag) }
        @inlinable set { set(Self.exponentFlag, newValue) }
    }

    /// The integer part starts with `0` and has more digits after it (forbidden by JSON and TOML).
    public var leadingZero: Bool {
        @inlinable get { has(Self.leadingZeroFlag) }
        @inlinable set { set(Self.leadingZeroFlag, newValue) }
    }

    /// Digits written before the point (and before any exponent).
    public var integerDigits: Int {
        @inlinable get { Int(integerCount) }
        @inlinable set { integerCount = UInt32(truncatingIfNeeded: newValue) }
    }

    public var fractionDigits: Int {
        @inlinable get { Int(fractionCount) }
        @inlinable set { fractionCount = UInt32(truncatingIfNeeded: newValue) }
    }

    public var exponentDigits: Int {
        @inlinable get { Int(exponentCount) }
        @inlinable set { exponentCount = UInt32(truncatingIfNeeded: newValue) }
    }

    /// No point, no exponent.
    @inlinable
    public var isInteger: Bool { flags & (Self.pointFlag | Self.exponentFlag) == 0 }

    /// The same value with the significand's trailing zeros moved into the exponent: the smallest significand, which a fast path
    /// bounded by the significand's size (Clinger, a `Float`'s 2^24) accepts more often. `12300000000` is `123e8`.
    @inlinable
    public var trimmed: DecimalLiteral {
        var literal = self
        while literal.significand != 0, literal.significand % 10 == 0 {
            literal.significand /= 10
            literal.exponent += 1
        }
        return literal
    }

    /// The literal's value as an integer when it is one and fits 64 bits with its sign: `-9223372036854775808` fits, one more does
    /// not. Nil for a fraction, an exponent, or an overflow.
    public var integerValue: Int64? {
        guard isInteger, !truncated, exponent >= 0, exponent <= 19 else { return nil }
        var magnitude = significand
        for _ in 0 ..< exponent {
            let (product, overflow) = magnitude.multipliedReportingOverflow(by: 10)
            guard !overflow else { return nil }
            magnitude = product
        }
        if negative {
            guard magnitude <= UInt64(Int64.max) + 1 else { return nil }
            return magnitude == UInt64(Int64.max) + 1 ? .min : -Int64(magnitude)
        }
        return magnitude <= UInt64(Int64.max) ? Int64(magnitude) : nil
    }
}

/// Reads ``DecimalLiteral``s.
public enum DecimalScanner {
    /// The literal at `start`, read as far as it goes: nil when no integer digit is there. A point not followed by a digit, or an
    /// `e` not followed by digits, is not consumed (``DecimalLiteral/end`` stops before it), so the caller sees what follows and
    /// its grammar decides. `separator` is allowed only between two digits.
    @inlinable
    public static func scan(_ bytes: [UInt8], from start: Int, separator: UInt8? = nil) -> DecimalLiteral? {
        bytes.withUnsafeBufferPointer { unsafe scan($0, from: start, separator: separator) }
    }

    /// As ``scan(_:from:separator:)-([UInt8],_,_)``, over a buffer. Inlined into the caller's loop: AemiJSON's own scan was
    /// `@inline(__always)`, and a call here cost its canada.json value tree 14 % more instructions.
    @inlinable
    public static func scan(_ bytes: UnsafeBufferPointer<UInt8>, from start: Int, separator: UInt8? = nil)
        -> DecimalLiteral?
    {
        guard start >= 0, start < bytes.count, let base = bytes.baseAddress else { return nil }
        var reader = unsafe Reader(
            base: base,
            count: bytes.count,
            index: start,
            separator: separator.map(Int.init) ?? -1
        )
        switch reader.quickRead() {
            case .read: return reader.literal
            case .none: return nil
            case .long:
                var precise = unsafe Reader(
                    base: base,
                    count: bytes.count,
                    index: start,
                    separator: separator.map(Int.init) ?? -1
                )
                return precise.preciseRead() ? precise.literal : nil
        }
    }

    @safe @usableFromInline
    struct Reader {
        @usableFromInline let base: UnsafePointer<UInt8>
        @usableFromInline let count: Int
        @usableFromInline var index: Int
        /// The separator byte, or -1.
        @usableFromInline let separator: Int
        @usableFromInline var literal = DecimalLiteral()
        /// Zeros after a significant digit, not yet folded into the significand (the precise pass).
        @usableFromInline var pendingZeros = 0
        @usableFromInline var significantDigits = 0

        @inlinable
        init(base: UnsafePointer<UInt8>, count: Int, index: Int, separator: Int) {
            unsafe self.base = base
            self.count = count
            self.index = index
            self.separator = separator
        }

        @usableFromInline
        enum Outcome {
            case read
            case none
            /// More than nineteen digits: the precise pass reads it.
            case long
        }

        /// The byte at `at`, or -1 outside the buffer.
        @inlinable
        func byte(_ at: Int) -> Int { at >= 0 && at < count ? Int(unsafe base[at]) : -1 }

        @inlinable
        static func isDigit(_ value: Int) -> Bool { value >= 0x30 && value <= 0x39 }

        /// The fast pass: every digit into the significand, eight at a time.
        @inlinable
        mutating func quickRead() -> Outcome {
            literal.start = index
            let sign = unsafe base[index]
            if sign == 0x2B || sign == 0x2D {
                literal.flags =
                    sign == 0x2D ? DecimalLiteral.signedFlag | DecimalLiteral.negativeFlag : DecimalLiteral.signedFlag
                index += 1
            }
            guard index < count, unsafe base[index] &- 0x30 < 10 else { return .none }
            let leadingZero = unsafe base[index] == 0x30
            // The integer part is one to three digits in most numbers (coordinates, prices, counts), where a word costs more than
            // the bytes: those go one by one, and only a longer run reaches the words.
            var integer = 0
            while integer < 3, index < count, unsafe base[index] &- 0x30 < 10 {
                literal.significand = literal.significand &* 10 &+ UInt64(unsafe base[index] &- 0x30)
                integer += 1
                index += 1
            }
            if integer == 3 || (index < count && Int(unsafe base[index]) == separator) {
                integer += quickDigits(after: integer)
            }
            literal.integerCount = UInt32(truncatingIfNeeded: integer)
            if leadingZero, integer > 1 { literal.flags |= DecimalLiteral.leadingZeroFlag }
            var fraction = 0
            if index + 1 < count, unsafe base[index] == 0x2E, unsafe base[index + 1] &- 0x30 < 10 {
                index += 1
                literal.flags |= DecimalLiteral.pointFlag
                fraction = quickDigits()
                literal.fractionCount = UInt32(truncatingIfNeeded: fraction)
                literal.exponent = -fraction
            }
            guard integer + fraction <= 19 else { return .long }
            if index < count, unsafe base[index] | 0x20 == 0x65 { readExponent() }
            literal.end = index
            return .read
        }

        /// A run of digits, every one into the significand, eight bytes at a time: a word's leading digits (all eight, or the
        /// run's last one to seven) are converted at once, shifted into place behind ASCII zeros.
        @inlinable
        mutating func quickDigits(after prior: Int = 0) -> Int {
            // `prior` digits were read just before, so a separator may come first.
            var digits = 0
            while index + 8 <= count {
                // SAFETY: `index + 8 <= count`, so the eight bytes are inside the buffer.
                let word = UInt64(littleEndian: unsafe UnsafeRawPointer(base + index).loadUnaligned(as: UInt64.self))
                let others = Self.nonDigitLanes(word)
                if others == 0 {
                    literal.significand = literal.significand &* 100_000_000 &+ Self.eightDigits(word)
                    digits += 8
                    index += 8
                    continue
                }
                let run = others.trailingZeroBitCount >> 3
                if run > 0 {
                    // The run's digits become the last `run` of eight, behind ASCII zeros.
                    let shift = UInt64(64 - 8 * run)
                    let aligned = word << shift | (0x3030_3030_3030_3030 & ((1 << shift) &- 1))
                    literal.significand = literal.significand &* Self.powerOfTen(run) &+ Self.eightDigits(aligned)
                    digits += run
                    index += run
                }
                // A separator between two digits continues the run; anything else ends it.
                guard separator >= 0, Int(unsafe base[index]) == separator, digits + prior > 0, index + 1 < count,
                    unsafe base[index + 1] &- 0x30 < 10
                else { return digits }
                index += 1
            }
            // Fewer than eight bytes left: one load of the eight ending at the buffer's end, shifted so the unread bytes are the low
            // lanes and zeros (not digits) the high ones; a number held in a buffer of its own length (AemiJSON) ends here.
            if index < count, count >= 8 {
                let left = count - index
                // SAFETY: `count >= 8`, so the eight bytes ending at `count` are inside the buffer.
                let word =
                    UInt64(littleEndian: unsafe UnsafeRawPointer(base + (count - 8)).loadUnaligned(as: UInt64.self))
                    >> UInt64(8 * (8 - left))
                let run = Self.nonDigitLanes(word).trailingZeroBitCount >> 3
                if run > 0 {
                    let shift = UInt64(64 - 8 * run)
                    let aligned = word << shift | (0x3030_3030_3030_3030 & ((1 << shift) &- 1))
                    literal.significand = literal.significand &* Self.powerOfTen(run) &+ Self.eightDigits(aligned)
                    digits += run
                    index += run
                }
                // A separator continues the run byte by byte below; anything else ends it.
                guard index < count, separator >= 0, Int(unsafe base[index]) == separator else { return digits }
            }
            while index < count {
                let value = unsafe base[index]
                let digit = value &- 0x30
                if digit < 10 {
                    literal.significand = literal.significand &* 10 &+ UInt64(digit)
                    digits += 1
                    index += 1
                } else if separator >= 0, Int(value) == separator, digits + prior > 0, index + 1 < count,
                    unsafe base[index + 1] &- 0x30 < 10
                {
                    index += 1
                } else {
                    break
                }
            }
            return digits
        }

        /// `0x80` in each lane that is not an ASCII digit, exactly: `x = byte ^ 0x30` is a digit when below 10, and adding
        /// `0x76` to its low seven bits sets the high bit from 10 up, with no carry out of the lane.
        @inlinable @inline(__always)
        static func nonDigitLanes(_ word: UInt64) -> UInt64 {
            let x = word ^ 0x3030_3030_3030_3030
            return (((x & 0x7F7F_7F7F_7F7F_7F7F) &+ 0x7676_7676_7676_7676) | x) & 0x8080_8080_8080_8080
        }

        @inlinable @inline(__always)
        static func powerOfTen(_ exponent: Int) -> UInt64 {
            switch exponent {
                case 1: 10
                case 2: 100
                case 3: 1000
                case 4: 10000
                case 5: 100_000
                case 6: 1_000_000
                case 7: 10_000_000
                default: 100_000_000
            }
        }

        /// The value of eight ASCII digits, the first in the lowest lane (simdjson's `parse_eight_digits_unrolled`).
        @inlinable @inline(__always)
        static func eightDigits(_ word: UInt64) -> UInt64 {
            var value = word &- 0x3030_3030_3030_3030
            value = (value &* 10) &+ (value >> 8)
            value =
                (((value & 0x0000_00FF_0000_00FF) &* 0x000F_4240_0000_0064)
                    &+ (((value >> 16) & 0x0000_00FF_0000_00FF) &* 0x0000_2710_0000_0001)) >> 32
            return value
        }

        /// An `e` or `E`, an optional sign and digits: the exponent, saturating. Not consumed without digits.
        @inlinable
        mutating func readExponent() {
            var at = index + 1
            var negative = false
            let sign = byte(at)
            if sign == 0x2B || sign == 0x2D {
                negative = sign == 0x2D
                at += 1
            }
            guard Self.isDigit(byte(at)) else { return }
            index = at
            literal.flags |= DecimalLiteral.exponentFlag
            var value = 0
            var digits = 0
            while true {
                let digit = byte(index)
                if Self.isDigit(digit) {
                    if value < 1 << 40 { value = value * 10 + (digit - 0x30) } else { literal.truncated = true }
                    digits += 1
                    index += 1
                } else if digit == separator, Self.isDigit(byte(index + 1)) {
                    index += 1
                } else {
                    break
                }
            }
            literal.exponentCount = UInt32(truncatingIfNeeded: digits)
            literal.exponent = Self.saturating(literal.exponent, plus: negative ? -value : value)
        }

        @inlinable
        static func saturating(_ a: Int, plus b: Int) -> Int { Swift.min(Swift.max(a + b, -(1 << 41)), 1 << 41) }

        // MARK: The precise pass, past nineteen digits (rare, out of line)

        /// The zero-aware pass: zeros count toward the nineteen only between significant digits.
        @usableFromInline
        mutating func preciseRead() -> Bool {
            literal.start = index
            let sign = byte(index)
            if sign == 0x2B || sign == 0x2D {
                literal.signed = true
                literal.negative = sign == 0x2D
                index += 1
            }
            guard Self.isDigit(byte(index)) else { return false }
            let leadingZero = byte(index) == 0x30
            literal.integerDigits = digits(fraction: false)
            literal.leadingZero = leadingZero && literal.integerDigits > 1
            if byte(index) == 0x2E, Self.isDigit(byte(index + 1)) {
                index += 1
                literal.hasPoint = true
                literal.fractionDigits = digits(fraction: true)
            }
            let marker = byte(index)
            if marker == 0x65 || marker == 0x45 { readExponent() }
            literal.exponent = Self.saturating(literal.exponent, plus: pendingZeros)
            literal.end = index
            return true
        }

        /// A run of digits with separators between them, zero-aware, byte by byte (an eight-digit word would fold padding zeros
        /// into the significand); returns how many digits.
        mutating func digits(fraction: Bool) -> Int {
            var digits = 0
            while true {
                let value = byte(index)
                if Self.isDigit(value) {
                    add(UInt64(value - 0x30), fraction: fraction)
                    digits += 1
                    index += 1
                } else if value == separator, digits > 0, Self.isDigit(byte(index + 1)) {
                    index += 1
                } else {
                    return digits
                }
            }
        }

        mutating func add(_ digit: UInt64, fraction: Bool) {
            if fraction { literal.exponent -= 1 }
            guard digit != 0 else {
                if significantDigits > 0 { pendingZeros += 1 }
                return
            }
            guard significantDigits + pendingZeros < 19 else {
                // Past nineteen: this digit and the zeros before it are dropped; their place values still count.
                literal.truncated = true
                literal.exponent += pendingZeros + 1
                pendingZeros = 0
                return
            }
            for _ in 0 ..< pendingZeros { literal.significand &*= 10 }
            literal.significand = literal.significand &* 10 &+ digit
            significantDigits += pendingZeros + 1
            pendingZeros = 0
        }
    }
}

extension DecimalFloat {
    #if !hasFeature(Embedded)
        /// The `Double` nearest to `literal` (written in `bytes`), correctly rounded: Clinger's fast path, then Eisel-Lemire, then the
        /// literal's digits rewritten short (at most 768 significant digits and a sticky one, separators dropped) for the
        /// locale-independent `Double(String)`. Never `strtod`.
        public static func double(_ literal: DecimalLiteral, in bytes: [UInt8], separator: UInt8? = nil) -> Double {
            if let fast = fastDouble(literal) { return fast }
            return LongDecimal.double(bytes[literal.start ..< literal.end], separator: separator) ?? .nan
        }

        /// As ``double(_:in:separator:)-(_,[UInt8],_)``, over a buffer (a parser holding a pointer to its source, AemiJSON).
        @inlinable
        public static func double(
            _ literal: DecimalLiteral,
            in bytes: UnsafeBufferPointer<UInt8>,
            separator: UInt8? = nil
        )
            -> Double
        {
            if let fast = fastDouble(literal) { return fast }
            return unsafe slowDouble(literal, in: bytes, separator: separator)
        }

        /// The long-decimal path of ``double(_:in:separator:)-(_,UnsafeBufferPointer<UInt8>,_)``, out of line.
        @usableFromInline
        static func slowDouble(_ literal: DecimalLiteral, in bytes: UnsafeBufferPointer<UInt8>, separator: UInt8?)
            -> Double
        {
            let text = unsafe Array(UnsafeBufferPointer(rebasing: bytes[literal.start ..< literal.end]))
            return LongDecimal.double(text[...], separator: separator) ?? .nan
        }

        /// The `Float` nearest to `literal`, rounded once (through `Double`, some short decimals round twice; AemiJSON decodes
        /// `Float` this way): Clinger at `Float` width, then `Float(String)` on the literal's short form.
        public static func float(
            _ literal: DecimalLiteral,
            in bytes: UnsafeBufferPointer<UInt8>,
            separator: UInt8? = nil
        )
            -> Float
        {
            let small = literal.trimmed
            if !small.truncated, small.significand <= 1 << 24,
                let fast = float(
                    significand: UInt32(truncatingIfNeeded: small.significand),
                    exponent: small.exponent,
                    negative: small.negative
                )
            {
                return fast
            }
            let text = unsafe Array(UnsafeBufferPointer(rebasing: bytes[literal.start ..< literal.end]))
            return LongDecimal.float(text[...], separator: separator) ?? .nan
        }

        /// As ``float(_:in:separator:)-(_,UnsafeBufferPointer<UInt8>,_)``.
        public static func float(_ literal: DecimalLiteral, in bytes: [UInt8], separator: UInt8? = nil) -> Float {
            bytes.withUnsafeBufferPointer { unsafe float(literal, in: $0, separator: separator) }
        }
    #endif

    /// Clinger, then Eisel-Lemire; nil when neither can prove the rounding.
    @inlinable
    public static func fastDouble(_ literal: DecimalLiteral) -> Double? {
        guard !literal.truncated else { return nil }
        if let clinger = double(
            significand: literal.significand,
            exponent: literal.exponent,
            negative: literal.negative
        ) {
            return clinger
        }
        return eiselLemire(significand: literal.significand, exponent: literal.exponent, negative: literal.negative)
    }
}

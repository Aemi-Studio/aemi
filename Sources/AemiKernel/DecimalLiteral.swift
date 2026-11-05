/// A decimal number as written, read in one pass (ADR 0031): `[+|-] digits [. digits] [(e|E) [+|-] digits]`, with an optional digit
/// separator allowed only between two digits (TOML's `_`). What it is (sign, the first nineteen significant digits, the power of
/// ten, whether digits were dropped) and how it was written (digit counts, a leading zero, where it ends), so each grammar decides
/// what it accepts and ``DecimalFloat/double(_:in:)`` turns it into the correctly rounded value.
///
/// Promoted from AemiJSON's `scanDecimal`, `scanPaddedDecimal` and `LongDecimal` (one implementation for JSON, TOML and YAML).
/// Zeros only pad: they count toward the nineteen digits only between significant digits, so `0.000…01` and `1.000…0` keep the
/// fast paths. Eight digits at a time are converted with SWAR when they are all digits (simdjson's `parse_eight_digits`).
public struct DecimalLiteral: Sendable, Equatable {
    public var negative = false
    /// A sign was written (`+` or `-`).
    public var signed = false
    /// The first nineteen significant digits, as an integer.
    public var significand: UInt64 = 0
    /// The power of ten `significand` is scaled by. Saturates far outside any finite `Double`.
    public var exponent = 0
    /// Significant digits were dropped, or the exponent saturated: only the slow path rounds it exactly.
    public var truncated = false
    /// Digits written before the point (and before any exponent).
    public var integerDigits = 0
    /// A point was written; ``fractionDigits`` says how many digits followed it.
    public var hasPoint = false
    public var fractionDigits = 0
    /// An exponent was written; ``exponentDigits`` says how many digits it has.
    public var hasExponent = false
    public var exponentDigits = 0
    /// The integer part starts with `0` and has more digits after it (forbidden by JSON and TOML).
    public var leadingZero = false
    /// The index of the literal's first byte, and the index just after its last.
    public var start = 0
    public var end = 0

    public init() {}

    /// No point, no exponent.
    public var isInteger: Bool { !hasPoint && !hasExponent }

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
    public static func scan(_ bytes: [UInt8], from start: Int, separator: UInt8? = nil) -> DecimalLiteral? {
        bytes.withUnsafeBufferPointer { unsafe scan($0, from: start, separator: separator) }
    }

    /// As ``scan(_:from:separator:)-([UInt8],_,_)``, over a buffer.
    public static func scan(_ bytes: UnsafeBufferPointer<UInt8>, from start: Int, separator: UInt8? = nil)
        -> DecimalLiteral?
    {
        var reader = unsafe Reader(bytes: bytes, index: start, separator: separator.map(Int.init) ?? -1)
        return reader.read()
    }

    @safe struct Reader {
        let bytes: UnsafeBufferPointer<UInt8>
        let count: Int
        var index: Int
        /// The separator byte, or -1.
        let separator: Int
        var literal = DecimalLiteral()
        /// Zeros after a significant digit, not yet folded into the significand.
        var pendingZeros = 0
        var significantDigits = 0

        init(bytes: UnsafeBufferPointer<UInt8>, index: Int, separator: Int) {
            unsafe self.bytes = bytes
            count = bytes.count
            self.index = index
            self.separator = separator
        }

        func byte(_ at: Int) -> Int { at >= 0 && at < count ? Int(unsafe bytes[at]) : -1 }

        static func isDigit(_ value: Int) -> Bool { value >= 0x30 && value <= 0x39 }

        mutating func read() -> DecimalLiteral? {
            guard index >= 0, index < count else { return nil }
            let start = index
            // Most numbers have at most nineteen digits: one tight pass that counts every digit, zeros too, decides them. Past
            // nineteen, the zero-aware pass below reads it again (AemiJSON's scanDecimal and scanPaddedDecimal, ADR 0031).
            if let literal = quickRead() { return literal }
            self = unsafe Reader(bytes: bytes, index: start, separator: separator)
            return preciseRead()
        }

        /// The literal when it has at most nineteen digits, or nil (then the precise pass reads it).
        mutating func quickRead() -> DecimalLiteral? {
            literal.start = index
            let sign = byte(index)
            if sign == 0x2B || sign == 0x2D {
                literal.signed = true
                literal.negative = sign == 0x2D
                index += 1
            }
            guard Self.isDigit(byte(index)) else { return nil }
            literal.leadingZero = byte(index) == 0x30
            literal.integerDigits = quickDigits()
            literal.leadingZero = literal.leadingZero && literal.integerDigits > 1
            if byte(index) == 0x2E, Self.isDigit(byte(index + 1)) {
                index += 1
                literal.hasPoint = true
                literal.fractionDigits = quickDigits()
                literal.exponent = -literal.fractionDigits
            }
            guard literal.integerDigits + literal.fractionDigits <= 19 else { return nil }
            let marker = byte(index)
            if marker == 0x65 || marker == 0x45 { readExponent() }
            literal.end = index
            return literal
        }

        /// A run of digits, every one into the significand, eight bytes at a time: a word's leading digits (all eight, or the
        /// run's last one to seven) are converted at once, shifted into place behind ASCII zeros (ADR 0031).
        mutating func quickDigits() -> Int {
            var digits = 0
            while index + 8 <= count, let base = unsafe bytes.baseAddress {
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
                guard Int(unsafe base[index]) == separator, digits > 0, Self.isDigit(byte(index + 1)) else {
                    return digits
                }
                index += 1
            }
            while true {
                let value = byte(index)
                let digit = value &- 0x30
                if digit >= 0, digit < 10 {
                    literal.significand = literal.significand &* 10 &+ UInt64(digit)
                    digits += 1
                    index += 1
                } else if value == separator, digits > 0, Self.isDigit(byte(index + 1)) {
                    index += 1
                } else {
                    return digits
                }
            }
        }

        /// `0x80` in each lane that is not an ASCII digit, exactly: `x = byte ^ 0x30` is a digit when below 10, and adding
        /// `0x76` to its low seven bits sets the high bit from 10 up, with no carry out of the lane.
        @inline(__always)
        static func nonDigitLanes(_ word: UInt64) -> UInt64 {
            let x = word ^ 0x3030_3030_3030_3030
            return (((x & 0x7F7F_7F7F_7F7F_7F7F) &+ 0x7676_7676_7676_7676) | x) & 0x8080_8080_8080_8080
        }

        @inline(__always)
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

        /// The zero-aware pass: zeros count toward the nineteen only between significant digits.
        mutating func preciseRead() -> DecimalLiteral? {
            guard index >= 0, index < count else { return nil }
            literal.start = index
            let sign = byte(index)
            if sign == 0x2B || sign == 0x2D {
                literal.signed = true
                literal.negative = sign == 0x2D
                index += 1
            }
            guard Self.isDigit(byte(index)) else { return nil }
            literal.leadingZero = byte(index) == 0x30
            literal.integerDigits = digits(fraction: false)
            literal.leadingZero = literal.leadingZero && literal.integerDigits > 1
            if byte(index) == 0x2E, Self.isDigit(byte(index + 1)) {
                index += 1
                literal.hasPoint = true
                literal.fractionDigits = digits(fraction: true)
            }
            let marker = byte(index)
            if marker == 0x65 || marker == 0x45 {
                readExponent()
            }
            literal.exponent = saturating(literal.exponent, plus: pendingZeros)
            literal.end = index
            return literal
        }

        /// A run of digits with separators between them; returns how many digits.
        mutating func digits(fraction: Bool) -> Int {
            var digits = 0
            // Eight digits at a time while they are all digits and fit the nineteen; once a word is not all digits, the rest of
            // the run goes byte by byte (retrying the word before every digit cost more than it saved).
            var words = true
            while true {
                if words, significantDigits > 0, pendingZeros == 0, significantDigits + 8 <= 19, index + 8 <= count,
                    let base = unsafe bytes.baseAddress
                {
                    // SAFETY: `index + 8 <= count`, so the eight bytes are inside the buffer.
                    let word = UInt64(
                        littleEndian: unsafe UnsafeRawPointer(base + index).loadUnaligned(as: UInt64.self)
                    )
                    if Self.allDigits(word) {
                        literal.significand = literal.significand &* 100_000_000 &+ Self.eightDigits(word)
                        significantDigits += 8
                        if fraction { literal.exponent -= 8 }
                        digits += 8
                        index += 8
                        continue
                    }
                    words = false
                }
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
            literal.hasExponent = true
            var value = 0
            var count = 0
            while true {
                let digit = byte(index)
                if Self.isDigit(digit) {
                    if value < 1 << 40 { value = value * 10 + (digit - 0x30) } else { literal.truncated = true }
                    count += 1
                    index += 1
                } else if digit == separator, Self.isDigit(byte(index + 1)) {
                    index += 1
                } else {
                    break
                }
            }
            literal.exponentDigits = count
            literal.exponent = saturating(literal.exponent, plus: negative ? -value : value)
        }

        func saturating(_ a: Int, plus b: Int) -> Int { Swift.min(Swift.max(a + b, -(1 << 41)), 1 << 41) }

        /// Every lane an ASCII digit (simdjson's `is_made_of_eight_digits_fast`).
        @inline(__always)
        static func allDigits(_ word: UInt64) -> Bool {
            (word & 0xF0F0_F0F0_F0F0_F0F0) | (((word &+ 0x0606_0606_0606_0606) & 0xF0F0_F0F0_F0F0_F0F0) >> 4)
                == 0x3333_3333_3333_3333
        }

        /// The value of eight ASCII digits, the first in the lowest lane (simdjson's `parse_eight_digits_unrolled`).
        @inline(__always)
        static func eightDigits(_ word: UInt64) -> UInt64 {
            var value = word &- 0x3030_3030_3030_3030
            value = (value &* 10) &+ (value >> 8)
            value =
                (((value & 0x0000_00FF_0000_00FF) &* 0x000F_4240_0000_0064)
                    &+ (((value >> 16) & 0x0000_00FF_0000_00FF) &* 0x0000_2710_0000_0001)) >> 32
            return value
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
        public static func double(
            _ literal: DecimalLiteral,
            in bytes: UnsafeBufferPointer<UInt8>,
            separator: UInt8? = nil
        )
            -> Double
        {
            if let fast = fastDouble(literal) { return fast }
            let text = unsafe Array(UnsafeBufferPointer(rebasing: bytes[literal.start ..< literal.end]))
            return LongDecimal.double(text[...], separator: separator) ?? .nan
        }

    #endif

    /// Clinger, then Eisel-Lemire; nil when neither can prove the rounding.
    @inlinable
    public static func fastDouble(_ literal: DecimalLiteral) -> Double? {
        guard !literal.truncated else { return nil }
        return double(significand: literal.significand, exponent: literal.exponent, negative: literal.negative)
            ?? eiselLemire(significand: literal.significand, exponent: literal.exponent, negative: literal.negative)
    }
}

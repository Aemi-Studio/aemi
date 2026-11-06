/// An integer of any size: YAML's unbounded integers, TLA+'s and Lean's `Int` and `Nat` (AemiFormal), JSON integers past 64 bits.
/// A sign and a magnitude in 64-bit limbs, least significant first, with no high zero limb (zero has none and is never negative).
/// Division truncates toward zero, as Swift's integers do. Parsing and printing go a chunk of digits at a time; multiplication is
/// schoolbook and division Knuth's algorithm D, so a number of n limbs costs O(n²) at worst.
public struct BigInt: Sendable, Hashable, Comparable, CustomStringConvertible, ExpressibleByIntegerLiteral {
    @usableFromInline var negative: Bool
    @usableFromInline var limbs: [UInt64]

    @usableFromInline
    init(negative: Bool, limbs: [UInt64]) {
        var trimmed = limbs
        while trimmed.last == 0 { trimmed.removeLast() }
        self.limbs = trimmed
        self.negative = negative && !trimmed.isEmpty
    }

    public init() { self.init(negative: false, limbs: []) }

    public init(_ value: some BinaryInteger) {
        let magnitude = value.magnitude
        var limbs: [UInt64] = []
        for word in magnitude.words { limbs.append(UInt64(word)) }
        self.init(negative: value < 0, limbs: limbs)
    }

    public init(integerLiteral value: Int64) { self.init(value) }

    /// `text` as an integer of `radix` (2 to 36): an optional sign, then at least one digit; nil for anything else.
    public init?(_ text: some StringProtocol, radix: Int = 10) {
        precondition((2 ... 36).contains(radix), "a radix is 2 to 36")
        var bytes = Substring(text).utf8[...]
        let negative = bytes.first == UInt8(ascii: "-")
        if negative || bytes.first == UInt8(ascii: "+") { bytes = bytes.dropFirst() }
        guard !bytes.isEmpty else { return nil }
        let (chunk, scale) = Self.chunk(radix)
        var limbs: [UInt64] = []
        var value: UInt64 = 0
        var digits = 0
        // The first chunk is short, so every later one is whole.
        var remaining = bytes.count % chunk
        if remaining == 0 { remaining = chunk }
        for byte in bytes {
            guard let digit = Self.digit(byte), digit < radix else { return nil }
            value = value * UInt64(radix) + UInt64(digit)
            digits += 1
            if digits == remaining {
                Self.multiplyAdd(&limbs, by: limbs.isEmpty ? 1 : scale, adding: value)
                (value, digits, remaining) = (0, 0, chunk)
            }
        }
        self.init(negative: negative, limbs: limbs)
    }

    public var description: String { toString() }

    /// Its digits in `radix` (2 to 36), with a leading `-` when it is negative.
    public func toString(radix: Int = 10, uppercase: Bool = false) -> String {
        precondition((2 ... 36).contains(radix), "a radix is 2 to 36")
        guard !limbs.isEmpty else { return "0" }
        let (chunk, scale) = Self.chunk(radix)
        var rest = limbs
        var chunks: [UInt64] = []
        while !rest.isEmpty { chunks.append(Self.divide(&rest, by: scale)) }
        var text = negative ? "-" : ""
        for (position, value) in chunks.reversed().enumerated() {
            let digits = String(value, radix: radix, uppercase: uppercase)
            // Digits are ASCII: counted as bytes, not characters, so no Unicode table is linked (ADR 0024, Embedded Swift).
            if position > 0 { text += String(repeating: "0", count: chunk - digits.utf8.count) }
            text += digits
        }
        return text
    }

    /// -1, 0 or 1.
    public var signum: Int { limbs.isEmpty ? 0 : (negative ? -1 : 1) }

    public var isZero: Bool { limbs.isEmpty }

    /// Its absolute value's bits, 0 for zero.
    public var bitWidth: Int { limbs.last.map { limbs.count * 64 - $0.leadingZeroBitCount } ?? 0 }

    // MARK: - Comparing

    public static func < (lhs: BigInt, rhs: BigInt) -> Bool {
        if lhs.negative != rhs.negative { return lhs.negative }
        let order = compare(lhs.limbs, rhs.limbs)
        return lhs.negative ? order > 0 : order < 0
    }

    // MARK: - Arithmetic

    public static prefix func - (value: BigInt) -> BigInt { BigInt(negative: !value.negative, limbs: value.limbs) }

    public static func + (lhs: BigInt, rhs: BigInt) -> BigInt {
        if lhs.negative == rhs.negative { return BigInt(negative: lhs.negative, limbs: add(lhs.limbs, rhs.limbs)) }
        let order = compare(lhs.limbs, rhs.limbs)
        if order == 0 { return BigInt() }
        return order > 0
            ? BigInt(negative: lhs.negative, limbs: subtract(lhs.limbs, rhs.limbs))
            : BigInt(negative: rhs.negative, limbs: subtract(rhs.limbs, lhs.limbs))
    }

    public static func - (lhs: BigInt, rhs: BigInt) -> BigInt { lhs + -rhs }

    public static func * (lhs: BigInt, rhs: BigInt) -> BigInt {
        BigInt(negative: lhs.negative != rhs.negative, limbs: multiply(lhs.limbs, rhs.limbs))
    }

    /// The quotient truncated toward zero, and the remainder with the dividend's sign; `divisor` must not be zero.
    public func quotientAndRemainder(dividingBy divisor: BigInt) -> (quotient: BigInt, remainder: BigInt) {
        precondition(!divisor.isZero, "division by zero")
        let (quotient, remainder) = Self.divide(limbs, by: divisor.limbs)
        return (
            BigInt(negative: negative != divisor.negative, limbs: quotient),
            BigInt(negative: negative, limbs: remainder)
        )
    }

    public static func / (lhs: BigInt, rhs: BigInt) -> BigInt { lhs.quotientAndRemainder(dividingBy: rhs).quotient }

    public static func % (lhs: BigInt, rhs: BigInt) -> BigInt { lhs.quotientAndRemainder(dividingBy: rhs).remainder }

    public static func += (lhs: inout BigInt, rhs: BigInt) { lhs = lhs + rhs }
    public static func -= (lhs: inout BigInt, rhs: BigInt) { lhs = lhs - rhs }
    public static func *= (lhs: inout BigInt, rhs: BigInt) { lhs = lhs * rhs }

    /// It to the power `exponent` (not negative), by squaring.
    public func power(_ exponent: Int) -> BigInt {
        precondition(exponent >= 0, "a negative exponent")
        var result: BigInt = 1
        var base = self
        var rest = exponent
        while rest > 0 {
            if rest & 1 == 1 { result *= base }
            rest >>= 1
            if rest > 0 { base *= base }
        }
        return result
    }
}

extension Int64 {
    /// `value`, when it fits.
    public init?(exactly value: BigInt) {
        guard value.limbs.count <= 1 else { return nil }
        let magnitude = value.limbs.first ?? 0
        if value.negative {
            guard magnitude <= UInt64(Int64.max) + 1 else { return nil }
            self = magnitude == UInt64(Int64.max) + 1 ? .min : -Int64(magnitude)
        } else {
            guard magnitude <= UInt64(Int64.max) else { return nil }
            self = Int64(magnitude)
        }
    }
}

extension UInt64 {
    /// `value`, when it fits.
    public init?(exactly value: BigInt) {
        guard !value.negative, value.limbs.count <= 1 else { return nil }
        self = value.limbs.first ?? 0
    }
}

// MARK: - Magnitudes

extension BigInt {
    /// The most digits of `radix` a limb holds, and `radix` to that power.
    @usableFromInline
    static func chunk(_ radix: Int) -> (digits: Int, scale: UInt64) {
        var digits = 0
        var scale: UInt64 = 1
        while true {
            let (next, overflow) = scale.multipliedReportingOverflow(by: UInt64(radix))
            if overflow { return (digits, scale) }
            scale = next
            digits += 1
        }
    }

    static func digit(_ byte: UInt8) -> Int? {
        switch byte {
            case UInt8(ascii: "0") ... UInt8(ascii: "9"): Int(byte - UInt8(ascii: "0"))
            case UInt8(ascii: "a") ... UInt8(ascii: "z"): Int(byte - UInt8(ascii: "a")) + 10
            case UInt8(ascii: "A") ... UInt8(ascii: "Z"): Int(byte - UInt8(ascii: "A")) + 10
            default: nil
        }
    }

    /// `limbs * factor + addend`, in place.
    static func multiplyAdd(_ limbs: inout [UInt64], by factor: UInt64, adding addend: UInt64) {
        var carry = addend
        for index in limbs.indices {
            let (high, low) = limbs[index].multipliedFullWidth(by: factor)
            let (sum, overflow) = low.addingReportingOverflow(carry)
            limbs[index] = sum
            carry = high &+ (overflow ? 1 : 0)
        }
        if carry != 0 { limbs.append(carry) }
    }

    /// `limbs / divisor` in place (high zero limbs dropped), returning the remainder.
    static func divide(_ limbs: inout [UInt64], by divisor: UInt64) -> UInt64 {
        var remainder: UInt64 = 0
        for index in limbs.indices.reversed() {
            (limbs[index], remainder) = divide128(remainder, limbs[index], by: divisor)
        }
        while limbs.last == 0 { limbs.removeLast() }
        return remainder
    }

    /// `(high, low) / divisor` where `high < divisor`: Hacker's Delight's `divlu`, two 64-by-32-bit steps. `dividingFullWidth` would
    /// do the same with the runtime's 128-bit division (`__udivti3`), which Embedded Swift does not carry (ADR 0024).
    static func divide128(_ high: UInt64, _ low: UInt64, by divisor: UInt64) -> (quotient: UInt64, remainder: UInt64) {
        let base: UInt64 = 1 << 32
        let shift = UInt64(divisor.leadingZeroBitCount)
        let v = divisor << shift
        let (v1, v0) = (v >> 32, v & 0xFFFF_FFFF)
        let u32 = shift == 0 ? high : (high << shift) | (low >> (64 - shift))
        let u10 = low << shift
        let (u1, u0) = (u10 >> 32, u10 & 0xFFFF_FFFF)
        var q1 = u32 / v1
        var rhat = u32 - q1 * v1
        while q1 >= base || q1 * v0 > base * rhat + u1 {
            q1 -= 1
            rhat += v1
            if rhat >= base { break }
        }
        let u21 = u32 &* base &+ u1 &- q1 &* v
        var q0 = u21 / v1
        rhat = u21 - q0 * v1
        while q0 >= base || q0 * v0 > base * rhat + u0 {
            q0 -= 1
            rhat += v1
            if rhat >= base { break }
        }
        return (q1 * base + q0, (u21 &* base &+ u0 &- q0 &* v) >> shift)
    }

    static func compare(_ a: [UInt64], _ b: [UInt64]) -> Int {
        if a.count != b.count { return a.count < b.count ? -1 : 1 }
        for index in a.indices.reversed() where a[index] != b[index] { return a[index] < b[index] ? -1 : 1 }
        return 0
    }

    static func add(_ a: [UInt64], _ b: [UInt64]) -> [UInt64] {
        let (long, short) = a.count >= b.count ? (a, b) : (b, a)
        var result = long
        var carry = false
        for index in result.indices {
            let other = index < short.count ? short[index] : 0
            guard index < short.count || carry else { break }
            let (partial, first) = result[index].addingReportingOverflow(other)
            let (sum, second) = partial.addingReportingOverflow(carry ? 1 : 0)
            result[index] = sum
            carry = first || second
        }
        if carry { result.append(1) }
        return result
    }

    /// `a - b`, where `a` is not smaller.
    static func subtract(_ a: [UInt64], _ b: [UInt64]) -> [UInt64] {
        var result = a
        var borrow = false
        for index in result.indices {
            let other = index < b.count ? b[index] : 0
            guard index < b.count || borrow else { break }
            let (partial, first) = result[index].subtractingReportingOverflow(other)
            let (difference, second) = partial.subtractingReportingOverflow(borrow ? 1 : 0)
            result[index] = difference
            borrow = first || second
        }
        while result.last == 0 { result.removeLast() }
        return result
    }

    static func multiply(_ a: [UInt64], _ b: [UInt64]) -> [UInt64] {
        guard !a.isEmpty, !b.isEmpty else { return [] }
        var result = [UInt64](repeating: 0, count: a.count + b.count)
        for i in a.indices {
            var carry: UInt64 = 0
            for j in b.indices {
                let (high, low) = a[i].multipliedFullWidth(by: b[j])
                let (sum1, overflow1) = result[i + j].addingReportingOverflow(low)
                let (sum2, overflow2) = sum1.addingReportingOverflow(carry)
                result[i + j] = sum2
                carry = high &+ (overflow1 ? 1 : 0) &+ (overflow2 ? 1 : 0)
            }
            result[i + b.count] = carry
        }
        while result.last == 0 { result.removeLast() }
        return result
    }

    /// Knuth's algorithm D (The Art of Computer Programming, 4.3.1): the quotient and remainder of two magnitudes.
    static func divide(_ dividend: [UInt64], by divisor: [UInt64]) -> (quotient: [UInt64], remainder: [UInt64]) {
        if compare(dividend, divisor) < 0 { return ([], dividend) }
        if divisor.count == 1 {
            var quotient = dividend
            let remainder = divide(&quotient, by: divisor[0])
            return (quotient, remainder == 0 ? [] : [remainder])
        }
        let n = divisor.count
        let m = dividend.count - n
        let shift = UInt64(divisor[n - 1].leadingZeroBitCount)
        let v = shiftedLeft(divisor, by: shift, extraLimb: false)
        var u = shiftedLeft(dividend, by: shift, extraLimb: true)
        var quotient = [UInt64](repeating: 0, count: m + 1)
        for j in stride(from: m, through: 0, by: -1) {
            // An estimate of the next quotient limb from the top two limbs, too large by at most two after refining.
            var qhat: UInt64
            var rhat: UInt64
            var rhatOverflow = false
            if u[j + n] >= v[n - 1] {
                qhat = .max
                (rhat, rhatOverflow) = u[j + n - 1].addingReportingOverflow(v[n - 1])
            } else {
                (qhat, rhat) = divide128(u[j + n], u[j + n - 1], by: v[n - 1])
            }
            while !rhatOverflow {
                let (high, low) = qhat.multipliedFullWidth(by: v[n - 2])
                guard high > rhat || (high == rhat && low > u[j + n - 2]) else { break }
                qhat -= 1
                (rhat, rhatOverflow) = rhat.addingReportingOverflow(v[n - 1])
            }
            // u[j ... j+n] -= qhat * v
            var borrow: UInt64 = 0
            var carry: UInt64 = 0
            for i in 0 ..< n {
                let (high, low) = qhat.multipliedFullWidth(by: v[i])
                let (product, overflow) = low.addingReportingOverflow(carry)
                carry = high &+ (overflow ? 1 : 0)
                let (difference, under1) = u[i + j].subtractingReportingOverflow(product)
                let (result, under2) = difference.subtractingReportingOverflow(borrow)
                u[i + j] = result
                borrow = (under1 ? 1 : 0) + (under2 ? 1 : 0)
            }
            let (top, under1) = u[j + n].subtractingReportingOverflow(carry)
            let (topResult, under2) = top.subtractingReportingOverflow(borrow)
            u[j + n] = topResult
            if under1 || under2 {
                // qhat was one too large: add v back.
                qhat -= 1
                var addCarry = false
                for i in 0 ..< n {
                    let (partial, first) = u[i + j].addingReportingOverflow(v[i])
                    let (sum, second) = partial.addingReportingOverflow(addCarry ? 1 : 0)
                    u[i + j] = sum
                    addCarry = first || second
                }
                u[j + n] &+= addCarry ? 1 : 0
            }
            quotient[j] = qhat
        }
        while quotient.last == 0 { quotient.removeLast() }
        var remainder = shiftedRight(Array(u[0 ..< n]), by: shift)
        while remainder.last == 0 { remainder.removeLast() }
        return (quotient, remainder)
    }

    static func shiftedLeft(_ limbs: [UInt64], by shift: UInt64, extraLimb: Bool) -> [UInt64] {
        var result = [UInt64](repeating: 0, count: limbs.count + (extraLimb ? 1 : 0))
        var carry: UInt64 = 0
        for index in limbs.indices {
            result[index] = shift == 0 ? limbs[index] : (limbs[index] << shift) | carry
            carry = shift == 0 ? 0 : limbs[index] >> (64 - shift)
        }
        if extraLimb { result[limbs.count] = carry }
        return result
    }

    static func shiftedRight(_ limbs: [UInt64], by shift: UInt64) -> [UInt64] {
        guard shift > 0 else { return limbs }
        var result = limbs
        for index in result.indices {
            let high = index + 1 < limbs.count ? limbs[index + 1] << (64 - shift) : 0
            result[index] = (limbs[index] >> shift) | high
        }
        return result
    }
}

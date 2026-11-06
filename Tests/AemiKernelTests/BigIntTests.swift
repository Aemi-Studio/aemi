import AemiTestKit
import Testing

@testable import AemiKernel

@Suite("BigInt")
struct BigIntTests {
    /// A random value of up to `limbs` 64-bit limbs, either sign, sometimes with runs of all-ones or zero limbs (where carries and
    /// algorithm D's rare branches live).
    private static func random(_ generator: inout SeededRNG, limbs: Int) -> BigInt {
        let count = generator.uniform(limbs + 1)
        var value = BigInt()
        for _ in 0 ..< count {
            let limb: UInt64 =
                switch generator.uniform(4) {
                    case 0: .max
                    case 1: 0
                    default: generator.next()
                }
            value = value * BigInt(UInt64.max) + value + BigInt(limb)
        }
        return generator.uniform(2) == 0 ? value : -value
    }

    @Test func `arithmetic agrees with Int128 wherever the values fit`() {
        var generator = SeededRNG(seed: 4)
        for _ in 0 ..< 5000 {
            let a = Int128(Int64(bitPattern: generator.next())) * Int128(Int32(truncatingIfNeeded: generator.next()))
            let b = Int128(Int64(bitPattern: generator.next())) >> Int128(generator.uniform(60))
            let (x, y) = (BigInt(a), BigInt(b))
            #expect(x + y == BigInt(a + b) && x - y == BigInt(a - b))
            if a.magnitude.leadingZeroBitCount > 64, b.magnitude.leadingZeroBitCount > 64 {
                #expect(x * y == BigInt(a * b))
            }
            if b != 0 {
                #expect(x / y == BigInt(a / b) && x % y == BigInt(a % b))
            }
            #expect((x < y) == (a < b) && x.description == String(a))
            #expect(BigInt(String(a, radix: 16), radix: 16) == x)
        }
    }

    @Test func `division by many-limb divisors holds q·b + r = a with |r| < |b| and r of a's sign`() {
        var generator = SeededRNG(seed: 9)
        for _ in 0 ..< 3000 {
            let a = Self.random(&generator, limbs: 8)
            let b = Self.random(&generator, limbs: 5)
            guard !b.isZero else { continue }
            let (q, r) = a.quotientAndRemainder(dividingBy: b)
            #expect(q * b + r == a, "\(a) / \(b)")
            #expect((r.signum == 0 || r.signum == a.signum) && (r.signum >= 0 ? r : -r) < (b.signum >= 0 ? b : -b))
            #expect((a * b) / b == a && (a + b) - b == a)
        }
    }

    @Test func `printing and parsing round trip in every radix; bad text is refused`() {
        var generator = SeededRNG(seed: 13)
        for _ in 0 ..< 500 {
            let value = Self.random(&generator, limbs: 6)
            for radix in [2, 8, 10, 16, 36] {
                #expect(BigInt(value.toString(radix: radix), radix: radix) == value, "\(value) in \(radix)")
            }
        }
        #expect(BigInt("-0") == BigInt() && BigInt("+12") == 12 && BigInt("0000000000000000000000000000001") == 1)
        for text in ["", "-", "+", "1_000", "12a", " 1", "0x10"] { #expect(BigInt(text) == nil, "\(text)") }
        #expect(
            BigInt("zz", radix: 36) == 1295 && BigInt("FF", radix: 16)?.toString(radix: 16, uppercase: true) == "FF"
        )
    }

    @Test func `the 128-by-64 division agrees with the standard library's at every edge and on random values`() {
        var generator = SeededRNG(seed: 21)
        let edges: [UInt64] = [1, 2, 3, 0xFFFF_FFFF, 0x1_0000_0000, 0x8000_0000_0000_0000, .max - 1, .max]
        var cases: [(UInt64, UInt64, UInt64)] = []
        for divisor in edges {
            for low in [0, 1, divisor &- 1, .max] { cases.append((divisor - 1, low, divisor)) }
        }
        for _ in 0 ..< 200_000 {
            let divisor = generator.next() >> UInt64(generator.uniform(64)) | 1
            cases.append((generator.next() % divisor, generator.next(), divisor))
        }
        for (high, low, divisor) in cases {
            let mine = BigInt.divide128(high, low, by: divisor)
            let standard = divisor.dividingFullWidth((high, low))
            #expect(
                mine.quotient == standard.quotient && mine.remainder == standard.remainder,
                "\(high) \(low) / \(divisor)"
            )
        }
    }

    @Test func `powers, limb edges and conversions`() {
        let two64 = BigInt(2).power(64)
        #expect(two64.description == "18446744073709551616" && two64.bitWidth == 65)
        #expect(BigInt(10).power(40).description == "1" + String(repeating: "0", count: 40))
        #expect(two64 - 1 == BigInt(UInt64.max) && (two64 * two64 - 1) / (two64 - 1) == two64 + 1)
        #expect(Int64(exactly: BigInt(Int64.min)) == .min && Int64(exactly: BigInt(UInt64(Int64.max) + 1)) == nil)
        #expect(
            UInt64(exactly: BigInt(UInt64.max)) == .max && UInt64(exactly: two64) == nil
                && UInt64(exactly: BigInt(-1)) == nil
        )
        #expect(BigInt() == -BigInt() && BigInt().signum == 0 && BigInt().description == "0")
    }
}

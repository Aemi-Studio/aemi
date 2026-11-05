#if !hasFeature(Embedded)
    /// Not in Embedded Swift: it ends in `Double(String)`, which needs the standard library's text support.
    ///
    /// Rewrites a decimal too long for the fast paths into a short one `Double(String)` rounds exactly (promoted from AemiJSON, ADR
    /// 0031): a binary64 value is decided by a decimal's first 767 significant digits, so 768 of them plus a sticky `1` for anything
    /// nonzero beyond round as the whole decimal would. The exponent saturates, so a huge one still reads as overflow or underflow.
    /// The standard library rejects decimals tens of thousands of digits long (on Linux, and for some inputs on macOS), which are
    /// still valid numbers in every format here.
    enum LongDecimal {
        static let maxSignificantDigits = 768

        /// The significant digits kept, how many were seen, whether a nonzero one was dropped, and the power of ten so far.
        private struct Mantissa {
            var kept: [UInt8] = []
            var seen = 0
            var droppedNonzero = false
            var exponent = 0
            var sawDigit = false
        }

        /// The value of `text` (`[+|-] digits [. digits] [(e|E) [+|-] digits]`, `separator` between digits), or nil when it is not
        /// one.
        static func double(_ text: ArraySlice<UInt8>, separator: UInt8? = nil) -> Double? {
            var index = text.startIndex
            var negative = false
            if index < text.endIndex, text[index] == 0x2B || text[index] == 0x2D {
                negative = text[index] == 0x2D
                index += 1
            }
            var mantissa = Self.mantissa(text, &index, separator: separator)
            guard mantissa.sawDigit, let exponent = Self.exponent(text, &index, separator: separator),
                index == text.endIndex
            else {
                return nil
            }
            let sign = negative ? "-" : ""
            if mantissa.kept.isEmpty { return Double(sign + "0") }
            mantissa.exponent += exponent + mantissa.seen - mantissa.kept.count
            if mantissa.droppedNonzero {
                mantissa.kept.append(0x31)
                mantissa.exponent -= 1
            } else {
                while mantissa.kept.count > 1, mantissa.kept[mantissa.kept.count - 1] == 0x30 {
                    mantissa.kept.removeLast()
                    mantissa.exponent += 1
                }
            }
            return Double(sign + String(decoding: mantissa.kept, as: UTF8.self) + "e" + String(mantissa.exponent))
        }

        /// The integer and fraction digits from `index`, which stops at the first byte that is neither (nor a separator).
        private static func mantissa(_ text: ArraySlice<UInt8>, _ index: inout Int, separator: UInt8?) -> Mantissa {
            var mantissa = Mantissa()
            var inFraction = false
            while index < text.endIndex {
                let byte = text[index]
                if byte == 0x2E, !inFraction {
                    inFraction = true
                } else if byte &- 0x30 < 10 {
                    mantissa.sawDigit = true
                    if inFraction { mantissa.exponent -= 1 }
                    if byte != 0x30 || mantissa.seen > 0 {
                        mantissa.seen += 1
                        if mantissa.kept.count < maxSignificantDigits {
                            mantissa.kept.append(byte)
                        } else if byte != 0x30 {
                            mantissa.droppedNonzero = true
                        }
                    }
                } else if byte != separator {
                    break
                }
                index += 1
            }
            return mantissa
        }

        /// The signed value of an `e`/`E` part at `index`, saturating at 2^40; zero when there is none, nil when it has no digit.
        private static func exponent(_ text: ArraySlice<UInt8>, _ index: inout Int, separator: UInt8?) -> Int? {
            guard index < text.endIndex, text[index] == 0x65 || text[index] == 0x45 else { return 0 }
            index += 1
            var negative = false
            if index < text.endIndex, text[index] == 0x2B || text[index] == 0x2D {
                negative = text[index] == 0x2D
                index += 1
            }
            var value = 0
            var digits = 0
            while index < text.endIndex, text[index] &- 0x30 < 10 || text[index] == separator {
                if text[index] != separator {
                    if value < 1 << 40 { value = value * 10 + Int(text[index] - 0x30) }
                    digits += 1
                }
                index += 1
            }
            return digits > 0 ? (negative ? -value : value) : nil
        }
    }
#endif

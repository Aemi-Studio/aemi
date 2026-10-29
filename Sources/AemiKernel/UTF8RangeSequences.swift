/// Splits a range of scalar values into the byte-range sequences that match exactly the UTF-8 encodings of its members: what a
/// byte-level automaton compiles a Unicode class into. Promoted from AemiRegex (aemi ADR 0018).
public enum UTF8RangeSequences {
    /// The sequences for `range`, in ascending order of scalar value. Surrogates are left out: no UTF-8 sequence encodes them.
    /// - Complexity: O(1) in the width of the range: at most a few dozen sequences for any range.
    public static func sequences(_ range: ClosedRange<UInt32>) -> [[ClosedRange<UInt8>]] {
        var output: [[ClosedRange<UInt8>]] = []
        var stack = [range]
        outer: while let current = stack.popLast() {
            let start = current.lowerBound
            let end = current.upperBound
            if start <= 0xDFFF, end >= 0xD800 {
                if end > 0xDFFF { stack.append(0xE000 ... end) }
                if start < 0xD800 { stack.append(start ... 0xD7FF) }
                continue
            }
            for max: UInt32 in [0x7F, 0x7FF, 0xFFFF] where start <= max && max < end {
                stack.append((max + 1) ... end)
                stack.append(start ... max)
                continue outer
            }
            if end <= 0x7F {
                output.append([UInt8(start) ... UInt8(end)])
                continue
            }
            for shift in [6, 12, 18] {
                let mask: UInt32 = (1 << UInt32(shift)) - 1
                guard (start & ~mask) != (end & ~mask) else { continue }
                if start & mask != 0 {
                    stack.append(((start | mask) + 1) ... end)
                    stack.append(start ... (start | mask))
                    continue outer
                }
                if end & mask != mask {
                    stack.append((end & ~mask) ... end)
                    stack.append(start ... ((end & ~mask) - 1))
                    continue outer
                }
            }
            output.append(zip(encode(start), encode(end)).map { $0 ... $1 })
        }
        return output
    }

    /// The UTF-8 encoding of a scalar value that is not a surrogate.
    public static func encode(_ scalar: UInt32) -> [UInt8] {
        switch scalar {
            case 0 ..< 0x80: [UInt8(scalar)]
            case 0x80 ..< 0x800: [0xC0 | UInt8(scalar >> 6), 0x80 | UInt8(scalar & 0x3F)]
            case 0x800 ..< 0x10000:
                [0xE0 | UInt8(scalar >> 12), 0x80 | UInt8((scalar >> 6) & 0x3F), 0x80 | UInt8(scalar & 0x3F)]
            default:
                [
                    0xF0 | UInt8(scalar >> 18), 0x80 | UInt8((scalar >> 12) & 0x3F),
                    0x80 | UInt8((scalar >> 6) & 0x3F), 0x80 | UInt8(scalar & 0x3F)
                ]
        }
    }
}

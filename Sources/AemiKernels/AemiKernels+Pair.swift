//
//  AemiKernels+Pair.swift
//  AemiKernels
//
//  The first position of one byte pair, in Swift SIMD: promoted from AemiRegex's literal prefilter (aemi ADR 0018). On arm64 the
//  compare lowers to `cmeq.16b`, on x86-64 to `pcmpeqb`; AemiRegex measured Swift SIMD within 1.0 to 1.4x of C NEON intrinsics for
//  compares like these, so there is no C kernel for it.
//
//  Memory safety: a load at `i` happens only after `i + 17 <= count`, for the shifted load of the second byte, so no read passes
//  `baseAddress + count`. The tests cover every length around the vector width and every start offset.
//

extension AemiKernels {
    /// The first index `i >= from` with `bytes[i] == first && bytes[i + 1] == second`, or `nil`.
    @inlinable
    public static func firstIndex(
        ofPair first: UInt8, _ second: UInt8, in bytes: UnsafeBufferPointer<UInt8>, from: Int
    ) -> Int? {
        guard from >= 0, from <= bytes.count, let base = bytes.baseAddress else { return nil }
        let count = bytes.count
        let a = SIMD16<UInt8>(repeating: first)
        let b = SIMD16<UInt8>(repeating: second)
        var i = from
        while i + 17 <= count {
            let hit = unsafe (pairLoad(base, i) .== a) .& (pairLoad(base, i + 1) .== b)
            if any(hit) { return i + pairFirstSet(hit) }
            i += 16
        }
        while i + 1 < count {
            // The tail, one byte at a time: a regex prefilter calls this once per candidate, so it allocates nothing.
            if unsafe base[i] == first, unsafe base[i + 1] == second { return i }
            i += 1
        }
        return nil
    }

    @usableFromInline static let laneWeights = SIMD16<UInt8>(1, 2, 4, 8, 16, 32, 64, 128, 1, 2, 4, 8, 16, 32, 64, 128)

    @inlinable
    static func pairLoad(_ base: UnsafePointer<UInt8>, _ index: Int) -> SIMD16<UInt8> {
        unsafe UnsafeRawPointer(base + index).loadUnaligned(as: SIMD16<UInt8>.self)
    }

    /// The index of the first true lane. NEON has no movemask, so the lanes are weighted and summed per half instead.
    @inlinable
    static func pairFirstSet(_ mask: SIMDMask<SIMD16<Int8>>) -> Int {
        let weighted = SIMD16<UInt8>(repeating: 0).replacing(with: laneWeights, where: mask)
        let bits = UInt32(weighted.lowHalf.wrappedSum()) | (UInt32(weighted.highHalf.wrappedSum()) << 8)
        return bits.trailingZeroBitCount
    }
}

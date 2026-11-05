//
//  AemiKernels+ByteSet.swift
//  AemiKernels
//
//  A set of bytes that a SIMD kernel can scan for, in the two nibble tables of `adf_index_of_set`: a byte is in the set iff
//  `low[b & 15] & high[b >> 4] != 0`. The tables hold up to eight distinct "rows" (the lower nibbles that occur with one upper
//  nibble), each row a bit; any set that has at most eight distinct rows is held exactly, and the characters a tokenizer stops at
//  usually do. A set that does not fit is refused, never approximated.
//

internal import CAemiKernels

extension AemiKernels {
    /// A set of bytes for ``firstIndex(inSet:base:count:backend:)``.
    public struct ByteSet: Sendable, Equatable {
        let low: SIMD16<UInt8>
        let high: SIMD16<UInt8>

        /// The set of `bytes`, or nil if it has more than eight distinct rows (the lower nibbles that occur with one upper nibble) and the two tables cannot
        /// hold it exactly.
        /// - Complexity: O(bytes.count).
        public init?(_ bytes: some Sequence<UInt8>) {
            var rows = [UInt16](repeating: 0, count: 16)
            for byte in bytes { rows[Int(byte >> 4)] |= 1 << UInt16(byte & 15) }
            var patterns: [UInt16] = []
            var low = SIMD16<UInt8>(repeating: 0)
            var high = SIMD16<UInt8>(repeating: 0)
            for (upper, row) in rows.enumerated() where row != 0 {
                let bit: Int
                if let found = patterns.firstIndex(of: row) {
                    bit = found
                } else {
                    guard patterns.count < 8 else { return nil }
                    patterns.append(row)
                    bit = patterns.count - 1
                }
                high[upper] = UInt8(1) << UInt8(bit)
                for lower in 0 ..< 16 where row & (1 << UInt16(lower)) != 0 { low[lower] |= UInt8(1) << UInt8(bit) }
            }
            self.low = low
            self.high = high
        }

        /// Whether `byte` is in the set.
        public func contains(_ byte: UInt8) -> Bool { low[Int(byte & 15)] & high[Int(byte >> 4)] != 0 }
    }

    /// The offset within `base[0..<count]` of the first byte that is in `set`, or `count` if none is. `.scalar` forces the reference loop.
    ///
    /// Owner/bounds: the caller owns `base[0..<count]` for the call.
    public static func firstIndex(
        inSet set: ByteSet,
        base: UnsafePointer<UInt8>,
        count: Int,
        backend: Backend = .fastest
    ) -> Int {
        guard count > 0 else { return 0 }
        var low = set.low
        var high = set.high
        return withUnsafeBytes(of: &low) { lowBytes in
            withUnsafeBytes(of: &high) { highBytes in
                // SAFETY: each table is 16 bytes, which is what the kernel reads from each pointer.
                guard let lowBase = lowBytes.baseAddress, let highBase = highBytes.baseAddress else { return count }
                let lowPointer = unsafe lowBase.assumingMemoryBound(to: UInt8.self)
                let highPointer = unsafe highBase.assumingMemoryBound(to: UInt8.self)
                if case .scalar = backend {
                    return unsafe adf_index_of_set_scalar(base, count, lowPointer, highPointer)
                }
                return unsafe adf_index_of_set(base, count, lowPointer, highPointer)
            }
        }
    }

    /// The offset within `base[0..<count]` of the first byte that is NOT in `set`, or `count` if every byte is: the end of a run of
    /// the set's bytes (spaces, digits, key bytes), on the same tables and backends (ADR 0031). `.scalar` forces the reference loop.
    ///
    /// Owner/bounds: the caller owns `base[0..<count]` for the call.
    public static func firstIndex(
        notInSet set: ByteSet,
        base: UnsafePointer<UInt8>,
        count: Int,
        backend: Backend = .fastest
    ) -> Int {
        guard count > 0 else { return 0 }
        var low = set.low
        var high = set.high
        let index = withUnsafeBytes(of: &low) { lowBytes in
            withUnsafeBytes(of: &high) { highBytes in
                // SAFETY: each table is 16 bytes, which is what the kernel reads from each pointer.
                guard let lowBase = lowBytes.baseAddress, let highBase = highBytes.baseAddress else { return count }
                let lowPointer = unsafe lowBase.assumingMemoryBound(to: UInt8.self)
                let highPointer = unsafe highBase.assumingMemoryBound(to: UInt8.self)
                if case .scalar = backend {
                    return unsafe adf_index_not_in_set_scalar(base, count, lowPointer, highPointer)
                }
                return unsafe adf_index_not_in_set(base, count, lowPointer, highPointer)
            }
        }
        // The kernel never returns more than `count`; the clamp (one conditional select) also gives this body a shape of its own.
        // Without it, Swift's function merging folds it with `firstIndex(inSet:base:count:)`, whose body differs only in the C
        // function called, into one shared body behind a thunk, and the set scan, AemiMarkdown's hot path, paid 23 % more
        // instructions per byte (5.58 to 6.86, measured; ADR 0031).
        return index < count ? index : count
    }

    /// The index in `bytes` of the first byte that is in `set`, or `nil` if none is.
    public static func firstIndex(inSet set: ByteSet, in bytes: [UInt8], backend: Backend = .fastest) -> Int? {
        let count = bytes.count
        guard count > 0 else { return nil }
        @unsafe func scan(_ source: UnsafeBufferPointer<UInt8>) -> Int {
            guard let base = source.baseAddress else { return count }
            return unsafe firstIndex(inSet: set, base: base, count: count, backend: backend)
        }
        let index = unsafe bytes.withUnsafeBufferPointer(scan)
        return index == count ? nil : index
    }
}

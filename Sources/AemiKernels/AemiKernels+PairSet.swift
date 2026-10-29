//
//  AemiKernels+PairSet.swift
//  AemiKernels
//
//  A set of byte pairs that the Teddy kernel scans for (`adf_pair_set_find`), promoted from AemiRegex's literal prefilter (aemi
//  ADR 0018). A position it offers may not be a pair (pairs that share a bucket accept each other's nibbles), but it never skips one
//  that is. Up to eight pairs are exact apart from nibble cross-products; more only add false candidates.
//

internal import CAemiKernels

extension AemiKernels {
    /// The table of a two-byte Teddy kernel for a set of byte pairs, and the scans that use it.
    public struct PairSet: Sendable, Equatable {
        private let table: [UInt8]

        /// - Parameter pairs: the pairs to find. Pair `k` goes to bucket `k % 8`.
        public init(_ pairs: [(first: UInt8, second: UInt8)]) {
            var table = [UInt8](repeating: 0, count: Int(ADF_PAIR_SET_TABLE_BYTES))
            for (index, pair) in pairs.enumerated() {
                let bucket = UInt8(1) << UInt8(index % 8)
                table[Int(pair.first & 15)] |= bucket
                table[16 + Int(pair.first >> 4)] |= bucket
                table[32 + Int(pair.second & 15)] |= bucket
                table[48 + Int(pair.second >> 4)] |= bucket
            }
            self.table = table
        }

        /// The first position `>= from` that may start one of the pairs, or nil. `.scalar` forces the reference loop.
        ///
        /// The C result is checked before it is used: a position below `from` or without a following byte would let a caller index
        /// out of bounds, so it stops the program instead.
        public func firstCandidate(
            in bytes: UnsafeBufferPointer<UInt8>, from: Int, backend: Backend = .fastest
        ) -> Int? {
            guard from >= 0, from <= bytes.count, let base = bytes.baseAddress else { return nil }
            let found = table.withUnsafeBufferPointer { table in
                if case .scalar = backend {
                    return unsafe adf_pair_set_find_scalar(table.baseAddress, base, bytes.count, from)
                }
                return unsafe adf_pair_set_find(table.baseAddress, base, bytes.count, from)
            }
            // `SIZE_MAX` arrives as -1.
            if found == -1 { return nil }
            precondition(
                found >= from && found + 1 < bytes.count,
                "the pair-set kernel returned \(found) for from \(from), count \(bytes.count)")
            return found
        }

        /// Every candidate from `from` on, ascending, written to `out` (at most `out.count`), in one call.
        /// - Returns: how many were written, and where to continue; the scan is complete when that is `bytes.count` or more.
        ///
        /// The count and the resume position are checked: the C side writes only inside `out`, but a wrong count would let a caller
        /// read stale entries, so a violated invariant stops the program.
        public func candidates(
            in bytes: UnsafeBufferPointer<UInt8>, from: Int, into out: UnsafeMutableBufferPointer<Int>
        ) -> (count: Int, resume: Int) {
            precondition(out.count >= 1, "the pair-set batch needs room for at least one candidate")
            guard from >= 0, from < bytes.count, let base = bytes.baseAddress, let target = out.baseAddress else {
                return (0, bytes.count)
            }
            var resume = 0
            let count = table.withUnsafeBufferPointer {
                unsafe adf_pair_set_candidates($0.baseAddress, base, bytes.count, from, target, out.count, &resume)
            }
            precondition(count >= 0 && count <= out.count, "the pair-set batch wrote \(count) of \(out.count)")
            precondition(resume > from || resume >= bytes.count, "the pair-set batch made no progress")
            return (count, resume)
        }
    }
}

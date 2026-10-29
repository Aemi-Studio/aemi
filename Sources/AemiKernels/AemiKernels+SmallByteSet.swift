//
//  AemiKernels+SmallByteSet.swift
//  AemiKernels
//
//  The first byte of a set of up to eight bytes, by comparing each 16-byte block with every member, in inlinable Swift SIMD:
//  promoted from AemiRegex's prefilter (aemi ADR 0018). Beside `firstIndex(inSet:base:count:)`, the C nibble-table kernel, which scans
//  long stretches faster: this one wins where a scan is called very often over short spans (a set of frequent letters), because it
//  inlines into the caller and costs no call. AemiRegex measured it 13% faster than the C kernel there.
//
//  Memory safety: a load at `i` happens only after `i + 16 <= count`; the tail is scalar.
//

extension AemiKernels {
    /// A set of up to eight bytes, broadcast once into SIMD lanes for ``firstIndex(in:from:)``.
    public struct SmallByteSet: Sendable, Equatable {
        /// The most members a small set holds; past it, a compare per member costs more than a table lookup.
        public static let capacity = 8

        @usableFromInline let members: [UInt8]
        @usableFromInline let needles: [SIMD16<UInt8>]

        /// The set of `bytes`, or nil when there are more than ``capacity`` or none.
        @inlinable
        public init?(_ bytes: [UInt8]) {
            guard !bytes.isEmpty, bytes.count <= Self.capacity else { return nil }
            members = bytes
            needles = bytes.map { SIMD16(repeating: $0) }
        }

        /// The first index `>= from` whose byte is in the set, or nil.
        @inlinable
        public func firstIndex(in bytes: UnsafeBufferPointer<UInt8>, from: Int) -> Int? {
            guard from >= 0, from <= bytes.count, let base = bytes.baseAddress else { return nil }
            let count = bytes.count
            var i = from
            while i + 16 <= count {
                let chunk = unsafe AemiKernels.pairLoad(base, i)
                let hit = needles.dropFirst().reduce(chunk .== needles[0]) { $0 .| (chunk .== $1) }
                if any(hit) { return i + AemiKernels.pairFirstSet(hit) }
                i += 16
            }
            while i < count {
                if members.contains(unsafe base[i]) { return i }
                i += 1
            }
            return nil
        }
    }
}

/// A set of byte values as a 256-bit bitmap: any set, exactly, with O(1) membership. Promoted from AemiRegex, whose compiled classes
/// are made of them (aemi ADR 0018). `AemiKernels.ByteSet` is the other byte set: two nibble tables a SIMD kernel scans with, which
/// hold only sets of up to eight rows.
public struct ByteBitmap: Hashable, Sendable {
    @usableFromInline var words = SIMD4<UInt64>()

    @inlinable
    public init() {}

    @inlinable
    public mutating func insert(_ range: ClosedRange<UInt8>) {
        for byte in range { words[Int(byte >> 6)] |= 1 << UInt64(byte & 63) }
    }

    @inlinable
    public mutating func formUnion(_ other: ByteBitmap) { words |= other.words }

    /// The bytes in the set, ascending.
    @inlinable
    public var members: [UInt8] { (0 ... 255).filter { contains(UInt8($0)) }.map { UInt8($0) } }

    @inlinable
    public func contains(_ byte: UInt8) -> Bool { (words[Int(byte >> 6)] >> UInt64(byte & 63)) & 1 != 0 }
}

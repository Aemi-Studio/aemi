/// A set of small integers below a fixed capacity, with O(1) insert, membership and clear, and iteration in insertion order (Briggs
/// and Torczon's sparse set). An automaton's thread list is one; clearing it costs nothing, however full it was. Promoted from
/// AemiRegex (aemi ADR 0018); inlinable, since an automaton calls it once per thread per byte.
public struct SparseSet: Sendable {
    @usableFromInline var storage: [Int32]
    @usableFromInline var sparse: [Int32]
    @usableFromInline var size = 0

    /// An empty set for values in `0 ..< capacity`.
    @inlinable
    public init(capacity: Int) {
        storage = [Int32](repeating: 0, count: capacity)
        sparse = [Int32](repeating: 0, count: capacity)
    }

    /// The members, in insertion order, in `dense[0 ..< count]`.
    @inlinable public var dense: [Int32] { storage }

    @inlinable public var count: Int { size }

    @inlinable public var isEmpty: Bool { size == 0 }

    @inlinable
    public func contains(_ value: Int) -> Bool {
        let slot = Int(sparse[value])
        return slot < size && Int(storage[slot]) == value
    }

    /// Adds `value`; the caller has checked ``contains(_:)``.
    @inlinable
    public mutating func insert(_ value: Int) {
        storage[size] = Int32(truncatingIfNeeded: value)
        sparse[value] = Int32(truncatingIfNeeded: size)
        size += 1
    }

    @inlinable
    public mutating func removeAll() { size = 0 }
}

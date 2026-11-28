/// A growable circular FIFO: O(1) append at the back and removal at the front, O(1) indexing from the
/// front, contiguous power-of-two storage that doubles only when full.
///
/// The replacement for `Array` used as a queue (`append` + `removeFirst()`, O(n) per removal) — a
/// waiter list, an eviction order, a dynamic table that inserts newest and evicts oldest. Index 0 is
/// the oldest element. Value semantics (copy-on-write through the backing array).
public struct RingQueue<Element> {
    /// `nil` in free slots; `slots.count` is 0 or a power of two.
    @usableFromInline var slots: ContiguousArray<Element?>
    /// Slot of the oldest element (meaningless when empty).
    @usableFromInline var head = 0
    @usableFromInline var size = 0

    /// An empty queue with room for at least `minimumCapacity` elements before it grows.
    @inlinable
    public init(minimumCapacity: Int = 0) {
        let capacity = minimumCapacity > 0 ? Self.roundUpToPowerOfTwo(minimumCapacity) : 0
        slots = ContiguousArray(repeating: nil, count: capacity)
    }

    @inlinable
    public init(_ elements: some Sequence<Element>) {
        self.init()
        for element in elements { append(element) }
    }

    /// Elements held without growing.
    @inlinable public var capacity: Int { slots.count }

    @inlinable
    static func roundUpToPowerOfTwo(_ value: Int) -> Int {
        value <= 1 ? 1 : 1 << (Int.bitWidth - (value - 1).leadingZeroBitCount)
    }

    /// The slot holding the element `offset` places from the front.
    @inlinable
    func slot(_ offset: Int) -> Int { (head + offset) & (slots.count - 1) }

    /// Adds `element` at the back.
    @inlinable
    public mutating func append(_ element: Element) {
        if size == slots.count { grow() }
        slots[slot(size)] = element
        size += 1
    }

    /// Removes and returns the front (oldest) element, or `nil` when empty.
    @inlinable
    public mutating func popFirst() -> Element? {
        guard size > 0 else { return nil }
        let element = slots[head].take()
        head = (head + 1) & (slots.count - 1)
        size -= 1
        return element
    }

    /// Removes and returns the front element; the queue must not be empty.
    @inlinable
    @discardableResult
    public mutating func removeFirst() -> Element {
        guard let element = popFirst() else { preconditionFailure("removeFirst on an empty RingQueue") }
        return element
    }

    /// Removes and returns the back (newest) element, or `nil` when empty.
    @inlinable
    public mutating func popLast() -> Element? {
        guard size > 0 else { return nil }
        size -= 1
        return slots[slot(size)].take()
    }

    /// Removes the element `offset` places from the front, shifting the shorter side (O(min(i, n-i))).
    @inlinable
    @discardableResult
    public mutating func remove(at offset: Int) -> Element {
        precondition(offset >= 0 && offset < size, "RingQueue index out of range")
        guard let element = slots[slot(offset)] else { preconditionFailure("RingQueue live slot is empty") }
        if offset < size / 2 {
            var index = offset
            while index > 0 {
                slots[slot(index)] = slots[slot(index - 1)]
                index -= 1
            }
            slots[head] = nil
            head = (head + 1) & (slots.count - 1)
        } else {
            for index in offset ..< size - 1 { slots[slot(index)] = slots[slot(index + 1)] }
            slots[slot(size - 1)] = nil
        }
        size -= 1
        return element
    }

    /// Removes the first element matching `predicate`, returning it.
    @inlinable
    public mutating func removeFirst(where predicate: (Element) throws -> Bool) rethrows -> Element? {
        for offset in 0 ..< size where try predicate(self[offset]) { return remove(at: offset) }
        return nil
    }

    /// Drops every element; keeps the slots when `keepingCapacity`.
    @inlinable
    public mutating func removeAll(keepingCapacity: Bool = true) {
        if keepingCapacity {
            for offset in 0 ..< size { slots[slot(offset)] = nil }
        } else {
            slots = []
        }
        head = 0
        size = 0
    }

    /// Doubles the slots (at least 4), laying the elements out from slot 0 in order.
    @usableFromInline
    mutating func grow() {
        let newCapacity = Swift.max(4, slots.count * 2)
        var grown = ContiguousArray<Element?>(repeating: nil, count: newCapacity)
        for offset in 0 ..< size { grown[offset] = slots[slot(offset)].take() }
        slots = grown
        head = 0
    }
}

extension RingQueue: RandomAccessCollection, MutableCollection {
    @inlinable public var startIndex: Int { 0 }
    @inlinable public var endIndex: Int { size }
    @inlinable public var count: Int { size }
    @inlinable public var isEmpty: Bool { size == 0 }

    /// The element `offset` places from the front (0 is the oldest).
    @inlinable
    public subscript(offset: Int) -> Element {
        get {
            precondition(offset >= 0 && offset < size, "RingQueue index out of range")
            guard let element = slots[slot(offset)] else { preconditionFailure("RingQueue live slot is empty") }
            return element
        }
        set {
            precondition(offset >= 0 && offset < size, "RingQueue index out of range")
            slots[slot(offset)] = newValue
        }
    }
}

extension RingQueue: Sendable where Element: Sendable {}

extension RingQueue: Equatable where Element: Equatable {
    @inlinable
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.elementsEqual(rhs) }
}

extension RingQueue: ExpressibleByArrayLiteral {
    @inlinable
    public init(arrayLiteral elements: Element...) { self.init(elements) }
}

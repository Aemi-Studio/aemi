/// A hash table of `Int32` values whose keys stay where the caller keeps them (ADR 0031): offsets into a parser's source or arena,
/// nodes of a tape. Open addressing with linear probing, each slot holding the full hash beside the value, so the caller's
/// equality runs only when 64 bits of hash agree, and growth rehashes from the stored hashes, never the keys (AemiInterner's
/// layout, without owning the bytes).
///
/// The hash is the caller's: ``KeyedHash`` for keys from untrusted input, so that no input can make the probes quadratic.
public struct HashIndex: Sendable {
    @usableFromInline
    struct Slot: Sendable {
        @usableFromInline var hash: UInt64
        /// The value plus one; 0 marks an empty slot.
        @usableFromInline var value: Int32

        @inlinable init(hash: UInt64, value: Int32) {
            self.hash = hash
            self.value = value
        }
    }

    @usableFromInline var slots: [Slot]
    @usableFromInline var stored = 0

    /// Room for `capacity` values before the first growth.
    public init(capacity: Int = 0) {
        var size = 16
        while size / 4 * 3 < capacity { size <<= 1 }
        slots = Array(repeating: Slot(hash: 0, value: 0), count: size)
    }

    /// How many values it holds.
    public var count: Int { stored }

    /// The first value under `hash` that `matches` accepts, or nil.
    @inlinable
    public func find(hash: UInt64, where matches: (Int32) -> Bool) -> Int32? {
        let mask = slots.count - 1
        var position = Int(truncatingIfNeeded: hash) & mask
        while true {
            let slot = slots[position]
            if slot.value == 0 { return nil }
            if slot.hash == hash, matches(slot.value - 1) { return slot.value - 1 }
            position = (position + 1) & mask
        }
    }

    /// Adds `value` under `hash`. - Precondition: `value` is non-negative and below `Int32.max`.
    @inlinable
    public mutating func insert(_ value: Int32, hash: UInt64) {
        precondition(value >= 0 && value < .max, "a HashIndex holds values from 0 to Int32.max - 1")
        if (stored + 1) * 4 > slots.count * 3 { grow() }
        place(Slot(hash: hash, value: value + 1))
        stored += 1
    }

    /// The value under `hash` that `matches` accepts; or, when there is none, inserts `value` and returns nil.
    @inlinable
    public mutating func findOrInsert(_ value: Int32, hash: UInt64, where matches: (Int32) -> Bool) -> Int32? {
        if let found = find(hash: hash, where: matches) { return found }
        insert(value, hash: hash)
        return nil
    }

    @inlinable
    mutating func place(_ slot: Slot) {
        let mask = slots.count - 1
        var position = Int(truncatingIfNeeded: slot.hash) & mask
        while slots[position].value != 0 { position = (position + 1) & mask }
        slots[position] = slot
    }

    @usableFromInline
    mutating func grow() {
        let old = slots
        slots = Array(repeating: Slot(hash: 0, value: 0), count: old.count * 2)
        for slot in old where slot.value != 0 { place(slot) }
    }
}

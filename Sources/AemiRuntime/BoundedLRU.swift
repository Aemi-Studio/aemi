//
//  BoundedLRU.swift
//  HTTPConcurrency
//
//  A capacity- and cost-bounded map with least-recently-used recency — the shared primitive behind
//  every table in this package that claims to be bounded (the rate-limit client budget, the session
//  store, the response cache). It exists because each hand-rolled version of that pattern repeated one
//  of two bugs. Either the cap was enforced by a *conditional* prune that only dropped idle entries,
//  so a flood of live ones grew the map without bound (CWE-400 resource exhaustion, reached through
//  the CWE-770 "allocate on an attacker-chosen key" door); or recency was a list of `class` nodes
//  holding strong `prev` *and* `next` references — a cycle ARC can never collect, so every evicted
//  entry stayed resident for the life of the process (CWE-401).
//
//  Recency here is an index-linked list threaded through a contiguous slab of slots: `Int32` offsets,
//  not object references, so there is nothing to cycle and the whole structure is one
//  `ContiguousArray` plus one `Dictionary`. Slots are appended lazily and reused from a free list, so
//  `capacity: 1_000_000` costs nothing until it is populated, and a freed slot clears its key and
//  value so both are released immediately rather than pinned by the slab.
//

/// A map bounded by both an entry count and a total cost, ordered by least-recent use.
///
/// Every operation is O(1) apart from ``reclaim(scanning:where:)``, which is O(`limit`) by
/// construction. Mutating operations promote the touched entry to the most-recently-used end;
/// ``value(forKey:)`` deliberately does not, so metrics and tests can observe without perturbing.
public struct BoundedLRU<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    /// What an insertion does when it would cross ``capacity`` or ``maxCost``.
    public enum Overflow: Sendable, CaseIterable {
        /// Drop least-recently-used entries to make room — the policy for a cache.
        case evictLeastRecentlyUsed

        /// Refuse the newcomer and keep every entry already tracked — the policy for a budget.
        ///
        /// An admission table (a rate limiter, a connection budget) must never let an
        /// attacker-chosen new identity displace a tracked legitimate one: that hands the attacker a
        /// way to reset any victim's budget on demand, which is worse than the flood it bounds
        /// (CWE-770). Failing closed on the newcomer is the correct trade.
        case reject
    }

    /// The outcome of ``insert(_:forKey:cost:)``.
    public enum Insertion: Sendable, Equatable {
        /// A new key was stored, after evicting `evicted` least-recently-used entries.
        case inserted(evicted: Int)

        /// An existing key's value was replaced in place, and its recency promoted.
        case replaced

        /// Nothing was stored.
        ///
        /// One of three things happened. The entry's own cost exceeds ``maxCost``, in which case any
        /// previously stored value for the key is *removed* — it can never be stored at that cost, so
        /// a caller must not read back a stale value it believes it has just overwritten. Or the map
        /// was full under ``Overflow/reject`` and the key is new, so nothing was displaced. Or the key
        /// was already present under ``Overflow/reject`` and the replacement would have crossed
        /// ``maxCost``, in which case the entry keeps the value it already had.
        case rejected
    }

    /// One entry plus its two recency neighbours, as offsets into the slab.
    ///
    /// `key` and `value` are optional purely so a freed slot can release them; a live slot always
    /// holds both.
    private struct Slot {
        var key: Key?
        var value: Value?
        var cost: Int
        /// The neighbour toward the most-recently-used end, or ``BoundedLRU/nowhere``.
        var previous: Int32
        /// The neighbour toward the least-recently-used end — or, for a freed slot, the next free
        /// slot.
        var next: Int32
    }

    /// The null offset: no neighbour, no head, no tail, no free slot.
    private static var nowhere: Int32 { -1 }

    private var slots: ContiguousArray<Slot>
    private var index: [Key: Int32]
    private var head: Int32
    private var tail: Int32
    private var freeList: Int32
    private var totalCost: Int

    /// The maximum number of entries the map will hold.
    public let capacity: Int

    /// The maximum total cost the map will hold, in the caller's own unit.
    public let maxCost: Int

    /// What an insertion does when it would cross ``capacity`` or ``maxCost``.
    public let overflow: Overflow

    /// Creates an empty map bounded to `capacity` entries and `maxCost` total cost.
    ///
    /// `capacity` is clamped to `Int32.max`, the width of a slab offset. `cost` is whatever unit the
    /// caller counts in — bytes for a response cache, the default `1` for a plain entry count.
    public init(capacity: Int, maxCost: Int = .max, overflow: Overflow = .evictLeastRecentlyUsed) {
        self.capacity = min(max(0, capacity), Int(Int32.max))
        self.maxCost = max(0, maxCost)
        self.overflow = overflow
        slots = []
        index = [:]
        head = Self.nowhere
        tail = Self.nowhere
        freeList = Self.nowhere
        totalCost = 0
    }

    /// The number of entries currently stored.
    public var count: Int {
        index.count
    }

    /// The sum of the costs of the entries currently stored.
    public var cost: Int {
        totalCost
    }

    /// Whether the map holds no entries.
    public var isEmpty: Bool {
        index.isEmpty
    }

    /// The value stored for `key`, without disturbing recency.
    ///
    /// For metrics, assertions and tests: a read that promoted would silently change which entry is
    /// evicted next, making the eviction order untestable.
    public func value(forKey key: Key) -> Value? {
        guard let position = index[key] else {
            return nil
        }
        return slots[Int(position)].value
    }

    /// The value stored for `key`, promoted to the most-recently-used end.
    public mutating func touchedValue(forKey key: Key) -> Value? {
        guard let position = index[key] else {
            return nil
        }
        promote(position)
        return slots[Int(position)].value
    }

    /// Mutates the value stored for `key` in place and promotes it, in a single lookup.
    ///
    /// Returns `nil` — without calling `body` — when `key` is absent, so a caller distinguishes a
    /// miss from a body that legitimately returns `nil`. This is the read-modify-write entry point:
    /// a caller that instead did `value(forKey:)`, mutated, then `insert(_:forKey:)` would pay three
    /// hashes and, worse, could interleave a check and an insert across two critical sections.
    public mutating func withValue<R>(forKey key: Key, _ body: (inout Value) -> R) -> R? {
        guard let position = index[key], var value = slots[Int(position)].value else {
            return nil
        }
        // Clear the stored reference first so `value` is uniquely referenced: a copy-on-write payload
        // is then mutated in place instead of paying for a defensive copy.
        slots[Int(position)].value = nil
        let result = body(&value)
        slots[Int(position)].value = value
        promote(position)
        return result
    }

    /// Stores `value` for `key` with `cost`, evicting or refusing per ``overflow`` when full.
    @discardableResult
    public mutating func insert(_ value: Value, forKey key: Key, cost: Int = 1) -> Insertion {
        let cost = max(0, cost)
        guard cost <= maxCost else {
            removeValue(forKey: key)  // never leave a stale value behind an oversized replacement
            return .rejected
        }
        if let position = index[key] {
            return replace(value, cost: cost, at: position)
        }
        var evicted = 0
        // `maxCost - cost` rather than `totalCost + cost`: the guard above proved `cost <= maxCost`,
        // so the subtraction cannot underflow, while the addition could overflow on a huge cost.
        while count >= capacity || totalCost > maxCost - cost {
            guard case .evictLeastRecentlyUsed = overflow, tail != Self.nowhere else {
                return .rejected
            }
            remove(at: tail)
            evicted += 1
        }
        store(value, forKey: key, cost: cost)
        return .inserted(evicted: evicted)
    }

    /// Removes `key`, returning the value it held.
    @discardableResult
    public mutating func removeValue(forKey key: Key) -> Value? {
        guard let position = index[key] else {
            return nil
        }
        return remove(at: position)
    }

    /// Removes every entry, releasing each value.
    ///
    /// `keepingCapacity` keeps the slab and index buffers allocated for reuse; the slots themselves
    /// are discarded either way, so nothing stays retained.
    public mutating func removeAll(keepingCapacity: Bool = true) {
        slots.removeAll(keepingCapacity: keepingCapacity)
        index.removeAll(keepingCapacity: keepingCapacity)
        head = Self.nowhere
        tail = Self.nowhere
        freeList = Self.nowhere
        totalCost = 0
    }

    /// Drops entries matching `shouldReclaim`, scanning at most `limit` slots from the
    /// least-recently-used end, and returns how many it dropped.
    ///
    /// The bounded, amortized replacement for a full-map prune scan. A caller sweeps a handful of the
    /// most-idle entries on each insertion instead of walking every entry when the map fills, so no
    /// single request is ever charged an O(*n*) pause — itself a denial-of-service surface once *n*
    /// is attacker-influenced (CWE-407).
    @discardableResult
    public mutating func reclaim(
        scanning limit: Int,
        where shouldReclaim: (Key, Value) -> Bool
    ) -> Int {
        var reclaimed = 0
        var scanned = 0
        var current = tail
        while current != Self.nowhere, scanned < limit {
            let candidate = current
            current = slots[Int(candidate)].previous
            scanned += 1
            guard let entry = entry(at: candidate), shouldReclaim(entry.key, entry.value) else {
                continue
            }
            remove(at: candidate)
            reclaimed += 1
        }
        return reclaimed
    }

    /// The live key and value at `position`, or `nil` for a freed slot.
    private func entry(at position: Int32) -> (key: Key, value: Value)? {
        let slot = Int(position)
        guard let key = slots[slot].key, let value = slots[slot].value else {
            return nil
        }
        return (key, value)
    }

    /// Replaces the value at `position`, re-basing the cost total and promoting the entry.
    ///
    /// A replacement crosses ``maxCost`` exactly as an insertion does whenever it displaces a cheaper
    /// value, so it answers to ``overflow`` in the same way: trim the least-recently-used end under
    /// ``Overflow/evictLeastRecentlyUsed``, refuse under ``Overflow/reject``.
    ///
    /// Refusing means *keeping* the entry it could not overwrite. The stale value that
    /// ``insert(_:forKey:cost:)`` drops on an oversized cost is unstorable at that cost forever, so
    /// there is nothing to keep; this refusal is transient, and dropping a tracked entry on it would
    /// hand any caller of a budget table a way to clear its own budget on demand — the displacement
    /// hazard ``Overflow/reject`` exists to deny (CWE-770), through the key's own front door.
    private mutating func replace(_ value: Value, cost: Int, at position: Int32) -> Insertion {
        let slot = Int(position)
        // `totalCost - existing > maxCost - cost` rather than `totalCost - existing + cost >
        // maxCost`: both sides are proven non-negative (`cost <= maxCost` by the caller's guard,
        // `existing <= totalCost` by construction), so neither can overflow on a huge cost.
        if totalCost - slots[slot].cost > maxCost - cost, case .reject = overflow {
            return .rejected
        }
        totalCost += cost - slots[slot].cost
        slots[slot].value = value
        slots[slot].cost = cost
        promote(position)
        trimToCost(protecting: position)
        return .replaced
    }

    /// Fills a fresh slot with `key`/`value` and links it at the most-recently-used end.
    private mutating func store(_ value: Value, forKey key: Key, cost: Int) {
        let position = allocate()
        let slot = Int(position)
        slots[slot].key = key
        slots[slot].value = value
        slots[slot].cost = cost
        index[key] = position
        totalCost += cost
        pushFront(position)
    }

    /// Evicts from the least-recently-used end until the cost bound holds again.
    ///
    /// Only under ``Overflow/evictLeastRecentlyUsed``, and never the entry at `position` — a replace
    /// must not evict the value it just stored.
    private mutating func trimToCost(protecting position: Int32) {
        guard case .evictLeastRecentlyUsed = overflow else {
            return
        }
        while totalCost > maxCost, tail != Self.nowhere, tail != position {
            remove(at: tail)
        }
    }

    /// Takes a slot off the free list, or appends one to the slab.
    private mutating func allocate() -> Int32 {
        if freeList != Self.nowhere {
            let reused = freeList
            freeList = slots[Int(reused)].next
            slots[Int(reused)].next = Self.nowhere
            return reused
        }
        let position = Int32(slots.count)
        slots.append(
            Slot(key: nil, value: nil, cost: 0, previous: Self.nowhere, next: Self.nowhere)
        )
        return position
    }

    /// Unlinks the entry at `position`, clears the slot onto the free list, and returns its value.
    @discardableResult
    private mutating func remove(at position: Int32) -> Value? {
        let slot = Int(position)
        unlink(position)
        if let key = slots[slot].key {
            index[key] = nil
        }
        let value = slots[slot].value
        totalCost -= slots[slot].cost
        slots[slot].key = nil  // release the key and value now, not when the slab is reused
        slots[slot].value = nil
        slots[slot].cost = 0
        slots[slot].previous = Self.nowhere
        slots[slot].next = freeList
        freeList = position
        return value
    }

    /// Moves `position` to the most-recently-used end.
    private mutating func promote(_ position: Int32) {
        guard head != position else {
            return
        }
        unlink(position)
        pushFront(position)
    }

    /// Detaches `position` from the recency list, mending its neighbours.
    private mutating func unlink(_ position: Int32) {
        let slot = Int(position)
        let previous = slots[slot].previous
        let next = slots[slot].next
        if previous == Self.nowhere {
            head = next
        } else {
            slots[Int(previous)].next = next
        }
        if next == Self.nowhere {
            tail = previous
        } else {
            slots[Int(next)].previous = previous
        }
        slots[slot].previous = Self.nowhere
        slots[slot].next = Self.nowhere
    }

    /// Links `position` at the most-recently-used end.
    private mutating func pushFront(_ position: Int32) {
        let slot = Int(position)
        slots[slot].previous = Self.nowhere
        slots[slot].next = head
        if head != Self.nowhere {
            slots[Int(head)].previous = position
        }
        head = position
        if tail == Self.nowhere {
            tail = position
        }
    }
}

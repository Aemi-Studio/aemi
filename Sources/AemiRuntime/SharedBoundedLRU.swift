//
//  SharedBoundedLRU.swift
//  HTTPConcurrency
//
//  The concurrent face of ``BoundedLRU``: a ``ShardedMutex`` over one `BoundedLRU` per shard, with a
//  single mutating entry point. That single entry point is the whole design. The bug this type exists
//  to make unrepresentable is the two-critical-section shape
//
//      if map.count >= cap { prune(&map) }      // section 1: decide there is room
//      map[key] = value                          // section 2: insert unconditionally
//
//  which is unbounded whenever the prune finds nothing to drop, and racy besides. ``withShard(for:_:)``
//  hands the caller the shard's map for one compound read-modify-write under one lock acquisition, so
//  the check and the insert structurally cannot come apart (CWE-400 / CWE-367).
//
//  The global bound is hard: `capacity` is divided across the shards by *floor*, and the shard count
//  is clamped so that division is at least one. Sharding therefore never raises the total above the
//  requested capacity — it can only lower it slightly, which is the safe direction. The cost is skew:
//  keys are spread by a per-process-seeded hash, so one shard can fill while another is empty and
//  evict (or refuse) a little earlier than a single global map would have.
//

/// A thread-safe, hard-bounded LRU map, sharded to keep unrelated keys off the same lock.
public final class SharedBoundedLRU<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    private let shards: ShardedMutex<BoundedLRU<Key, Value>>

    deinit {
        // No teardown beyond ARC; the sharded Mutex releases with the instance.
    }

    /// Creates a map holding at most `capacity` entries and `maxCost` total cost across all shards.
    ///
    /// `shards` is a hint: it is clamped to `capacity` (so every shard of a non-empty map gets at
    /// least one entry) and then rounded up to a power of two. Use `1` when a test needs a
    /// deterministic eviction order.
    ///
    /// `capacity: 0` (or negative) means *disabled* and is honoured literally: every shard is built
    /// with capacity zero, so the map refuses every insertion and retains nothing. Rounding it up to
    /// one instead would leave a switched-off cache holding one attacker-chosen entry (CWE-400).
    public init(
        capacity: Int,
        maxCost: Int = .max,
        overflow: BoundedLRU<Key, Value>.Overflow = .evictLeastRecentlyUsed,
        shards: Int = 1
    ) {
        let requested = max(1, min(shards, max(1, capacity)))
        let count = Self.roundedDownToPowerOfTwo(requested)
        // `count <= capacity` whenever `capacity >= 1`, so the floor division is at least one there;
        // at `capacity <= 0` it is zero, which is exactly the requested disabled map.
        let perShardCapacity = max(0, capacity) / count
        let perShardCost = maxCost == .max ? .max : maxCost / count
        self.shards = ShardedMutex(shards: count) { _ in
            BoundedLRU(capacity: perShardCapacity, maxCost: perShardCost, overflow: overflow)
        }
    }

    /// The number of entries across every shard — a metrics read, not a consistent snapshot.
    public var totalCount: Int {
        shards.withEveryLock(Self.entryCount).reduce(0, +)
    }

    /// The total cost across every shard — a metrics read, not a consistent snapshot.
    public var totalCost: Int {
        shards.withEveryLock(Self.entryCost).reduce(0, +)
    }

    /// Runs `body` with exclusive access to the ``BoundedLRU`` shard owning `key`.
    ///
    /// The only mutating entry point, deliberately: one lock acquisition for one compound
    /// read-modify-write, so a caller cannot split a capacity check from the insert it guards.
    public func withShard<R>(for key: Key, _ body: (inout BoundedLRU<Key, Value>) -> R) -> R {
        shards.withLock(forKey: key, body)
    }

    /// Empties every shard.
    public func removeAll() {
        _ = shards.withEveryLock { $0.removeAll() }
    }

    /// One shard's entry count, as a function reference rather than a closure (SwiftLint's
    /// `prefer_key_path` rejects a property-access closure even where the `inout` parameter makes a
    /// key path impossible).
    private static func entryCount(_ map: inout BoundedLRU<Key, Value>) -> Int {
        map.count
    }

    /// One shard's total cost — see ``entryCount(_:)`` for why this is not a closure.
    private static func entryCost(_ map: inout BoundedLRU<Key, Value>) -> Int {
        map.cost
    }

    /// `value` rounded *down* to a power of two, so `shardCount * (capacity / shardCount) <=
    /// capacity` and the global bound stays hard.
    private static func roundedDownToPowerOfTwo(_ value: Int) -> Int {
        1 << (Int.bitWidth - 1 - max(1, value).leadingZeroBitCount)
    }
}

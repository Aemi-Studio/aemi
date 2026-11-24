//
//  ShardedMutexTests.swift
//  HTTPConcurrencyTests
//
//  ``ShardedMutex`` and ``SharedBoundedLRU``: the lock partition preserves mutual exclusion, and — the
//  point of the whole exercise — the capacity bound is *global* and hard, not per shard. Sharding a
//  bounded table is where a cap quietly turns into `shards × cap`, so the bound is asserted under
//  concurrent inserts and across capacities that do not divide evenly (audit finding 9, CWE-400).
//

import AemiRuntime
import Testing

/// Requested shard count → the power-of-two count actually allocated.
private let shardCountVectors: [(requested: Int, expected: Int)] = [
    (1, 1), (2, 2), (3, 4), (4, 4), (5, 8), (8, 8), (9, 16)
]

/// Global capacity → requested shard count, including capacities that do not divide evenly.
private let boundVectors: [(capacity: Int, shards: Int)] = [
    (1, 1), (4, 8), (10, 8), (64, 8), (100, 8), (1_000, 16), (100_000, 8)
]

/// Reads a shard's value.
///
/// A named function rather than `{ $0 }` because SwiftLint's `prefer_key_path` rejects an identity
/// closure even where no key path can be substituted (the parameter is `inout`).
private func shardValue(_ value: inout Int) -> Int {
    value
}

@Test(
    "the shard count is the requested count rounded up to a power of two",
    arguments: shardCountVectors
)
func shardCountRoundsUp(requested: Int, expected: Int) {
    let mutex = ShardedMutex<Int>(shards: requested) { _ in 0 }
    #expect(mutex.shardCount == expected)
}

@Test("every shard is initialized from its own index")
func shardsAreIndividuallySeeded() {
    let mutex = ShardedMutex<Int>(shards: 4) { index in index &* 10 }
    #expect(mutex.withEveryLock(shardValue).sorted() == [0, 10, 20, 30])
}

@Test("concurrent increments across shards lose no update")
func concurrentIncrementsAreExclusive() async {
    let mutex = ShardedMutex<Int>(shards: 8) { _ in 0 }
    await withTaskGroup(of: Void.self) { group in
        for worker in 0 ..< 8 {
            group.addTask {
                for step in 0 ..< 1_000 {
                    mutex.withLock(forKey: worker &* 1_000 &+ step) { $0 += 1 }
                }
            }
        }
    }
    #expect(mutex.withEveryLock(shardValue).reduce(0, +) == 8_000)
}

@Test("the global capacity bound holds across shards under concurrent inserts")
func globalCapacityBoundHoldsUnderConcurrency() async {
    let map = SharedBoundedLRU<Int, Int>(capacity: 64, shards: 8)
    await withTaskGroup(of: Void.self) { group in
        for worker in 0 ..< 8 {
            group.addTask {
                for step in 0 ..< 2_000 {
                    let key = worker &* 2_000 &+ step
                    _ = map.withShard(for: key) { $0.insert(key, forKey: key) }
                }
            }
        }
    }
    #expect(map.totalCount <= 64)
    #expect(map.totalCount > 0)
}

@Test(
    "sharding never raises the global bound above the requested capacity",
    arguments: boundVectors
)
func shardingNeverRaisesTheGlobalBound(capacity: Int, shards: Int) {
    let map = SharedBoundedLRU<Int, Int>(capacity: capacity, shards: shards)
    for key in 0 ..< (capacity &* 4 &+ 64) {
        _ = map.withShard(for: key) { $0.insert(key, forKey: key) }
    }
    #expect(map.totalCount <= capacity)
}

@Test(
    "a disabled (zero or negative) capacity retains nothing",
    arguments: [0, -1, -1_000]
)
func disabledCapacityRetainsNothing(capacity: Int) {
    // A caller asking for a *disabled* cache must get one. Clamping the per-shard division up to one
    // turned `capacity: 0` into "hold exactly one entry", so a deployment that switched a cache off
    // still retained an attacker-chosen key (CWE-400, the bound not meaning what it advertises).
    let map = SharedBoundedLRU<Int, Int>(capacity: capacity, shards: 8)
    for key in 0 ..< 64 {
        #expect(map.withShard(for: key) { $0.insert(key, forKey: key) } == .rejected)
    }
    #expect(map.totalCount == 0)
    #expect(map.withShard(for: 0) { $0.value(forKey: 0) } == nil)
}

@Test("a reject-overflow map refuses newcomers instead of evicting incumbents")
func rejectOverflowSurvivesSharding() {
    let map = SharedBoundedLRU<Int, Int>(capacity: 8, overflow: .reject, shards: 1)
    for key in 0 ..< 8 {
        _ = map.withShard(for: key) { $0.insert(key, forKey: key) }
    }
    for key in 8 ..< 1_000 {
        #expect(map.withShard(for: key) { $0.insert(key, forKey: key) } == .rejected)
    }
    #expect(map.totalCount == 8)
    for key in 0 ..< 8 {
        #expect(map.withShard(for: key) { $0.value(forKey: key) } == key)
    }
}

@Test("removeAll empties every shard")
func removeAllEmptiesEveryShard() {
    let map = SharedBoundedLRU<Int, Int>(capacity: 256, shards: 8)
    for key in 0 ..< 128 {
        _ = map.withShard(for: key) { $0.insert(key, forKey: key) }
    }
    #expect(map.totalCount == 128)
    map.removeAll()
    #expect(map.totalCount == 0)
    #expect(map.totalCost == 0)
}

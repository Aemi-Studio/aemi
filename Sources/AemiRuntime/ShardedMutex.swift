//
//  ShardedMutex.swift
//  HTTPConcurrency
//
//  One logical value split across N independently locked shards, so unrelated keys do not contend on
//  the same lock. `Mutex` (from `Synchronization`) is non-copyable and therefore cannot live in an
//  array, so each shard is a small final class holding one — the same shape already used by every
//  Mutex-guarded middleware in this package, just factored out and multiplied.
//
//  Shard choice is `hashValue & mask`. Swift seeds `Hasher` per process, so a remote attacker cannot
//  compute which keys collide onto one shard and cannot deliberately hot-spot a single lock — the
//  same property that makes Swift's `Dictionary` resistant to algorithmic-complexity attacks
//  (CWE-407, the HashDoS class).
//

internal import Synchronization

/// A value partitioned across a power-of-two number of independently locked shards.
///
/// A caller never sees the partition: it names a key, and ``withLock(forKey:_:)`` hands it exclusive
/// access to that key's shard. Cross-shard work is deliberately awkward (only ``withEveryLock(_:)``,
/// which takes every lock in turn and is for metrics and teardown), because a compound operation that
/// spans shards is not atomic.
public final class ShardedMutex<Value: Sendable>: Sendable {
    /// One shard: a class purely because `Mutex` is non-copyable and so cannot be an array element.
    private final class Shard: Sendable {
        let mutex: Mutex<Value>

        init(_ value: Value) {
            mutex = Mutex(value)
        }

        deinit {
            // No teardown beyond ARC; the Mutex releases with the instance.
        }
    }

    private let shards: [Shard]
    private let mask: UInt

    /// The number of shards actually allocated — the requested count rounded up to a power of two.
    public let shardCount: Int

    deinit {
        // No teardown beyond ARC; each shard's Mutex releases with it.
    }

    /// Creates `shards` (rounded up to a power of two) shards, each initialized by `value`.
    ///
    /// `value` receives the shard's index, so a caller that has to divide a global budget can hand
    /// each shard its own slice.
    public init(shards: Int, value: @Sendable (Int) -> Value) {
        let count = Self.roundedUpToPowerOfTwo(max(1, shards))
        shardCount = count
        mask = UInt(count - 1)
        self.shards = (0 ..< count).map { Shard(value($0)) }
    }

    /// Runs `body` with exclusive access to the shard owning `key`.
    ///
    /// One lock acquisition per call: a compound read-modify-write belongs *inside* `body`, never
    /// split across two calls — splitting a "is there room?" check from the insert that follows it is
    /// exactly how a bounded map stops being bounded.
    public func withLock<R>(
        forKey key: some Hashable,
        _ body: (inout Value) throws -> R
    ) rethrows -> R {
        try shards[shardIndex(for: key)].mutex.withLock { try body(&$0) }
    }

    /// Runs `body` against every shard in turn, returning one result per shard.
    ///
    /// For metrics and teardown only. The shards are locked one at a time, so the results are a
    /// smear across time rather than a consistent snapshot.
    public func withEveryLock<R>(_ body: (inout Value) -> R) -> [R] {
        shards.map { shard in shard.mutex.withLock { body(&$0) } }
    }

    /// The shard owning `key`.
    private func shardIndex(for key: some Hashable) -> Int {
        Int(UInt(bitPattern: key.hashValue) & mask)
    }

    /// `value` rounded up to a power of two, so the shard index is a mask rather than a modulo.
    private static func roundedUpToPowerOfTwo(_ value: Int) -> Int {
        guard value > 1 else {
            return 1
        }
        return 1 << (Int.bitWidth - (value - 1).leadingZeroBitCount)
    }
}

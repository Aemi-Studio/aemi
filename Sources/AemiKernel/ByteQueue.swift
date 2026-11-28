/// A FIFO of bytes in one contiguous array, read from a cursor instead of shifting on every read.
///
/// The rolling buffer a stream parser keeps (a socket's unparsed tail, a framer's partial message):
/// append what arrives, parse ``readable`` or ``withUnsafeReadableBytes(_:)``, ``consume(_:)`` what
/// was parsed. `Array.removeFirst(n)` per read moves every remaining byte each time; here a read only
/// advances ``head``, and the storage is reclaimed under one policy:
///
/// - fully drained (the common case, a chunk carrying whole messages): emptied in O(1), capacity kept;
/// - otherwise the dead prefix is shifted out only once it is at least ``compactionThreshold`` bytes
///   *and* at least as large as the live bytes, so every byte is moved O(1) times amortized and the
///   storage stays within twice the live bytes (plus the threshold);
/// - storage grown past ``retainedCapacityLimit`` (one large upload) is released once the live bytes
///   fit under the limit, instead of staying resident for the life of the connection.
public struct ByteQueue: Sendable {
    @usableFromInline var storage: [UInt8]
    /// Offset of the first unread byte in `storage`.
    @usableFromInline var head = 0
    /// The smallest dead prefix worth a shift (see the type's reclamation policy).
    public let compactionThreshold: Int
    /// Storage capacity kept across drains; larger storage is released once the live bytes fit.
    public let retainedCapacityLimit: Int

    /// - Parameters:
    ///   - minimumCapacity: bytes reserved up front.
    ///   - compactionThreshold: the smallest dead prefix shifted out while live bytes remain.
    ///   - retainedCapacityLimit: capacity kept across drains (unbounded by default).
    @inlinable
    public init(minimumCapacity: Int = 0, compactionThreshold: Int = 16_384, retainedCapacityLimit: Int = .max) {
        storage = []
        storage.reserveCapacity(minimumCapacity)
        self.compactionThreshold = max(0, compactionThreshold)
        self.retainedCapacityLimit = max(0, retainedCapacityLimit)
    }

    /// Unread bytes.
    @inlinable public var count: Int { storage.count - head }

    @inlinable public var isEmpty: Bool { storage.count == head }

    /// Bytes the storage holds without reallocating, including the dead prefix.
    @inlinable public var capacity: Int { storage.capacity }

    /// The unread bytes, indexed from `head` (not from 0) as an `ArraySlice` is.
    @inlinable public var readable: ArraySlice<UInt8> { storage[head...] }

    /// The unread byte at `offset` from the front.
    @inlinable
    public subscript(offset: Int) -> UInt8 {
        precondition(offset >= 0 && offset < count, "ByteQueue offset out of range")
        return storage[head + offset]
    }

    /// Calls `body` with the unread bytes; the pointer must not escape `body`.
    @inlinable
    public func withUnsafeReadableBytes<Result, Failure: Error>(
        _ body: (UnsafeRawBufferPointer) throws(Failure) -> Result
    ) throws(Failure) -> Result {
        let start = head
        let result: Swift.Result<Result, Failure> = storage.withUnsafeBytes { raw in
            do throws(Failure) {
                return .success(try unsafe body(unsafe UnsafeRawBufferPointer(rebasing: raw[start...])))
            } catch {
                return .failure(error)
            }
        }
        return try result.get()
    }

    @inlinable
    public mutating func append(_ byte: UInt8) { storage.append(byte) }

    @inlinable
    public mutating func append(contentsOf bytes: some Sequence<UInt8>) { storage.append(contentsOf: bytes) }

    /// Appends `bytes` (copied).
    @inlinable
    public mutating func append(_ bytes: UnsafeRawBufferPointer) { unsafe storage.append(contentsOf: bytes) }

    /// Marks the first `n` unread bytes read, reclaiming storage per the type's policy.
    @inlinable
    public mutating func consume(_ n: Int) {
        precondition(n >= 0 && n <= count, "ByteQueue.consume past the unread bytes")
        head += n
        reclaim()
    }

    /// The first `n` unread bytes, copied out, then consumed.
    @inlinable
    public mutating func take(_ n: Int) -> [UInt8] {
        precondition(n >= 0 && n <= count, "ByteQueue.take past the unread bytes")
        let out = Array(storage[head ..< head + n])
        consume(n)
        return out
    }

    /// Drops every byte; keeps the storage when `keepingCapacity` and it is under the retained limit.
    @inlinable
    public mutating func removeAll(keepingCapacity: Bool = true) {
        storage.removeAll(keepingCapacity: keepingCapacity && storage.capacity <= retainedCapacityLimit)
        head = 0
    }

    @inlinable
    mutating func reclaim() {
        let live = count
        if live == 0 {
            // `removeFirst` of everything is the cheapest Array path that keeps the storage (measured
            // ~30% under `removeAll(keepingCapacity:)` on a 1.5 KB-per-read drain loop).
            storage.removeFirst(head)
            head = 0
            if storage.capacity > retainedCapacityLimit { storage = [] }
            return
        }
        if storage.capacity > retainedCapacityLimit, live <= retainedCapacityLimit {
            // Release: the live bytes move into storage sized for them, not for the past peak.
            storage = Array(storage[head...])
            head = 0
        } else if head >= compactionThreshold, head >= live {
            storage.removeFirst(head)
            head = 0
        }
    }
}

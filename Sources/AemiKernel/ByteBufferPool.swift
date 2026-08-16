private import Synchronization

/// A thread-safe pool of reusable `[UInt8]` scratch buffers that cuts allocation churn on encode
/// hot paths (e.g. a server encoding many values). Relocated and generalized from ADJSON's
/// `EncoderBufferPool`, which used a single process-global pool; this is an instantiable pool so
/// each subsystem can keep its own. Guarded by `Synchronization.Mutex`.
public final class ByteBufferPool: Sendable {
    private let storage = Mutex<[[UInt8]]>([])
    private let maxBufferCapacity: Int
    private let maxPooled: Int

    /// - Parameters:
    ///   - maxBufferCapacity: a recycled buffer grown past this is dropped (its capacity released)
    ///     instead of pooled, so one oversized encode can't pin large allocations for the process
    ///     lifetime. Default 1 MiB.
    ///   - maxPooled: the most buffers retained at once. Default 32.
    public init(maxBufferCapacity: Int = 1 << 20, maxPooled: Int = 32) {
        self.maxBufferCapacity = maxBufferCapacity
        self.maxPooled = maxPooled
    }

    /// Borrows a buffer from the pool, or a fresh empty one when the pool is empty.
    public func take() -> [UInt8] {
        (storage.withLock { $0.popLast() }) ?? []
    }

    /// Returns a buffer to the pool, cleared but keeping its capacity, subject to the size/count caps.
    ///
    /// Takes ownership (`consuming`) so the clear runs in place: a still-shared array would force
    /// `removeAll(keepingCapacity:)` to copy rather than reuse the storage.
    public func recycle(_ buffer: consuming [UInt8]) {
        guard buffer.capacity <= maxBufferCapacity else { return }
        var cleared = buffer  // move (not copy) out of the consumed parameter
        cleared.removeAll(keepingCapacity: true)
        storage.withLock { pool in
            if pool.count < maxPooled { pool.append(cleared) }
        }
    }
}

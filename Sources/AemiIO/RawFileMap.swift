#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Read-only shared memory mapping of a file.
///
/// `capacity` bytes of virtual address space are reserved once at open. Virtual
/// reservation is free and there is no `mremap` on Darwin, so a caller may map
/// more than the current file length and let the file grow underneath the
/// mapping (pages become valid as the file is extended; no remap needed).
///
/// **Caller contract.** The mapping hands out *borrowed* views into foreign memory —
/// either the lifetime-unchecked raw pointer of ``region(offset:count:)`` (for zero-copy
/// callers that hold the pointer across calls) or the lifetime-checked, non-escapable
/// ``RawSpan`` of ``withRegion(offset:count:_:)`` (the safe path new scoped readers should
/// prefer). Either way the caller must (1) only read bytes that are backed by
/// the file — touching a page past the file's current end faults — and (2) keep
/// the backing file from shrinking below any range it still reads, since a
/// mapped region over truncated-away bytes is undefined. The read access policy
/// is `MADV_RANDOM`; ``prefetch(offset:length:)`` schedules a localized readahead
/// without changing that global policy.
@safe public final class RawFileMap: @unchecked Sendable {
    /// The naked mapping pointer is private: callers get only the bounded
    /// `region` views, so the unsafe pointer never leaves this type.
    private let base: UnsafeRawPointer
    /// Reserved length of the mapping in bytes.
    public let capacity: Int

    public init(fileDescriptor: Int32, capacity: Int) throws(IOError) {
        // `mmap` rejects a zero length with EINVAL; surface it as a clear precondition failure.
        guard capacity > 0 else { throw IOError(errno: EINVAL, op: "mmap(capacity: \(capacity))") }
        let ptr = unsafe mmap(nil, capacity, PROT_READ, MAP_SHARED, fileDescriptor, 0)
        guard let ptr = unsafe ptr, unsafe ptr != MAP_FAILED else { throw IOError.capturingErrno("mmap(\(capacity))") }
        unsafe self.base = UnsafeRawPointer(ptr)
        self.capacity = capacity
        // Random-access workloads (e.g. tree descent) shouldn't let read-ahead
        // pollute the cache.
        _ = unsafe madvise(UnsafeMutableRawPointer(mutating: ptr), capacity, MADV_RANDOM)
    }

    deinit {
        _ = unsafe munmap(UnsafeMutableRawPointer(mutating: base), capacity)
    }

    /// Debug-only spatial guard shared by ``region(offset:count:)`` and ``withRegion(offset:count:_:)``:
    /// the requested `offset ..< offset + count` window must lie within the reserved mapping. The
    /// arithmetic is overflow-safe — `count <= capacity` first, so `capacity - count` cannot underflow,
    /// then `offset <= capacity - count`. Compiled out of release builds, so the documented
    /// "not bounds-checked" hot path is unchanged. It cannot see the file's *committed* length, so the
    /// file-shrink / faulting-page half of the contract still rests with the caller.
    @inline(__always)
    private func assertRegionWithinMapping(offset: Int, count: Int) {
        assert(
            offset >= 0 && count >= 0 && count <= capacity && offset <= capacity - count,
            "RawFileMap.region(offset: \(offset), count: \(count)) escapes the \(capacity)-byte mapping")
    }

    /// Borrowed, **lifetime-unchecked** view of `count` bytes at `offset`, as a raw pointer.
    ///
    /// - Warning: The returned ``UnsafeRawBufferPointer`` is only valid while (1) this `RawFileMap` is
    ///   alive — its `deinit` `munmap`s the region, so any pointer that outlives the map is a
    ///   use-after-free — and (2) the named bytes stay backed by the file's committed length. Neither
    ///   is enforced by the type system. This zero-copy escape hatch exists for callers (e.g. a B-tree
    ///   that vends page pointers held across calls for the mapping's whole lifetime) that structurally
    ///   cannot scope the view to a closure. **New code that _can_ scope its access should prefer
    ///   ``withRegion(offset:count:_:)``**, which hands back a ``RawSpan`` the compiler forbids from
    ///   escaping the mapping.
    ///
    /// Not bounds-checked in release: the caller guarantees `offset + count` lies within the file's
    /// committed length (see the type's caller contract). A debug build asserts the *spatial* bound
    /// against `capacity`.
    @inline(__always)
    public func region(offset: Int, count: Int) -> UnsafeRawBufferPointer {
        assertRegionWithinMapping(offset: offset, count: count)
        return unsafe UnsafeRawBufferPointer(start: base + offset, count: count)
    }

    /// Invoke `body` with a **lifetime-checked** ``RawSpan`` over `count` bytes at `offset`, returning
    /// its result. The span is borrowed only for the duration of the call and is `~Escapable`, so the
    /// compiler *statically* prevents it from outliving the mapping — closing the use-after-`munmap`
    /// gap that ``region(offset:count:)`` leaves to the caller. The safe path for any new reader that
    /// can express its access as a scoped closure.
    ///
    /// Same *spatial* contract as ``region``: `offset` and `count` must land within the reserved
    /// mapping (asserted in debug). The *temporal* half still rests with the caller — a span over a
    /// page past the file's committed end faults on access, since neither this method nor `RawSpan`
    /// can observe the file's current length.
    @inline(__always)
    public func withRegion<R>(
        offset: Int, count: Int, _ body: (_ region: RawSpan) throws -> R
    ) rethrows -> R {
        assertRegionWithinMapping(offset: offset, count: count)
        let bytes = unsafe UnsafeRawBufferPointer(start: base + offset, count: count)
        return try body(unsafe RawSpan(_unsafeBytes: bytes))
    }

    /// Advisory readahead for `length` bytes starting at `offset`. `MADV_WILLNEED`
    /// only schedules a prefetch for the named range — unlike `MADV_SEQUENTIAL` it
    /// does not change the mapping's global policy, so a scan can prefetch ahead
    /// without disturbing concurrent random-access readers. The range is clamped to
    /// the reserved capacity; a tail beyond the committed file is harmless (those
    /// pages simply are not resident and never get touched in correct use).
    @inline(__always)
    public func prefetch(offset: Int, length: Int) {
        guard offset < capacity, length > 0 else { return }
        let clamped = min(length, capacity - offset)
        _ = unsafe madvise(UnsafeMutableRawPointer(mutating: base + offset), clamped, MADV_WILLNEED)
    }
}

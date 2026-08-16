public import Synchronization

/// Atomic operations on 8-byte `UInt64` cells living in shared / foreign memory — e.g. an
/// mmap'd cross-process lock file. `Synchronization.Atomic<UInt64>` is laid out exactly like a
/// plain `UInt64` (`@_rawLayout`), so a correctly aligned cell can be accessed atomically in
/// place by reinterpreting its address. These emit the same acquire/release/CAS instructions the
/// former C11 `<stdatomic.h>` shim did, now in pure Swift with no extra dependency.
///
/// The caller guarantees the pointer is 8-byte aligned and that the cell stays mapped for the
/// duration of the access (the bit pattern of any `UInt64`, including a zero-filled cell, is a
/// valid atomic value — trivial atomics carry no side metadata, exactly as `_Atomic uint64_t`).
public enum SharedAtomicU64 {
    // 8-byte alignment is the caller's contract (see the type doc). Atomics on a
    // misaligned address are UB on strict-alignment targets, so each entry asserts
    // it in debug (compiled out of release — like `RawFileMap.region`'s bounds
    // assert), turning silent misuse into a test failure.

    /// Atomic acquire load of the `UInt64` at `pointer`.
    @inlinable
    public static func loadAcquire(_ pointer: UnsafeRawPointer) -> UInt64 {
        assert(UInt(bitPattern: pointer) & 7 == 0, "SharedAtomicU64 requires an 8-byte-aligned pointer")
        return unsafe pointer.assumingMemoryBound(to: Atomic<UInt64>.self).pointee.load(ordering: .acquiring)
    }

    /// Atomic release store of `value` to the `UInt64` at `pointer`.
    @inlinable
    public static func storeRelease(_ pointer: UnsafeMutableRawPointer, _ value: UInt64) {
        assert(UInt(bitPattern: pointer) & 7 == 0, "SharedAtomicU64 requires an 8-byte-aligned pointer")
        unsafe pointer.assumingMemoryBound(to: Atomic<UInt64>.self).pointee
            .store(value, ordering: .releasing)
    }

    /// Strong compare-and-exchange (acquire-release on success, acquire on failure) of the
    /// `UInt64` at `pointer`. Returns whether the exchange happened.
    @inlinable
    public static func compareExchangeAcqRel(
        _ pointer: UnsafeMutableRawPointer, expected: UInt64, desired: UInt64
    ) -> Bool {
        assert(UInt(bitPattern: pointer) & 7 == 0, "SharedAtomicU64 requires an 8-byte-aligned pointer")
        return unsafe pointer.assumingMemoryBound(to: Atomic<UInt64>.self).pointee
            .compareExchange(expected: expected, desired: desired, ordering: .acquiringAndReleasing)
            .exchanged
    }
}

# ``AemiIO``

POSIX storage primitives: buffered file channel, read-only memory mapping, cross-process atomics.

## Overview

`AemiIO` holds the platform storage layer extracted from the database engine — positioned and
vectored I/O with durability profiles (`F_BARRIERFSYNC` / `F_FULLFSYNC` / `fdatasync`), read-only
`mmap` views, and C11 cross-process atomics for the shared-memory reader registry. Stdlib + libc
only; no Foundation, no external package.

### Choosing a durability profile

``DurabilityProfile`` trades crash-consistency against latency: ``DurabilityProfile/barrier`` orders
this file's writes ahead of later ones without a device cache flush (a power loss may still drop the
last few writes), ``DurabilityProfile/full`` additionally flushes the drive cache (power-loss durable,
significantly slower), and ``DurabilityProfile/none`` skips syncing entirely (benchmarks and
throwaway data only). Reach for `barrier` for ordinary crash-consistency and `full` only where a
write must survive sudden power loss.

``SharedAtomicU64`` provides acquire / release / compare-exchange on **8-byte-aligned** `UInt64`
cells in shared memory (e.g. an mmap'd cross-process lock file); the caller's table layout guarantees
that alignment. It is pure Swift over `Synchronization.Atomic<UInt64>`, which is laid out exactly like
a plain `UInt64` (`@_rawLayout`), so a correctly aligned cell is accessed atomically in place — the
same acquire/release/CAS instructions a C11 `_Atomic uint64_t` would emit, with no C and no extra
dependency.

## Topics

### File channel

- ``PosixFile``
- ``DurabilityProfile``

### Memory mapping

- ``RawFileMap``

### Shared-memory atomics

- ``SharedAtomicU64``

### Errors

- ``IOError``

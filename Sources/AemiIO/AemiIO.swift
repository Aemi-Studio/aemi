// AemiIO — POSIX storage primitives: a positioned file handle (``PosixFile``)
// with vectored writes and durability syncs, a read-only memory mapping
// (``RawFileMap``), and cross-process atomics on shared memory
// (``SharedAtomicU64``, pure-Swift over `Synchronization.Atomic`).
// Stdlib + platform libc only (Darwin / Glibc); no Foundation. Adopts SE-0458
// strict memory safety — every pointer / mmap construct is explicitly `unsafe`.

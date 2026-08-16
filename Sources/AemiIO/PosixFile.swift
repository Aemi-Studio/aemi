import Synchronization

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// POSIX-backed file handle exposing positioned reads/writes, a gather
/// (vectored) write, durability syncs, and space management. All calls are
/// stateless per-fd operations (`pread`/`pwrite`/`fcntl`), safe to issue from
/// any thread, so the type is `@unchecked Sendable`: the only mutable state is
/// the atomic double-close guard.
public final class PosixFile: @unchecked Sendable {
    public let fileDescriptor: Int32
    private let closeOnDeinit: Bool
    /// Guards against double-close: a second close on a recycled descriptor
    /// number would tear down an unrelated file out from under another thread.
    private let closed = Atomic<Bool>(false)

    public enum Mode: Sendable {
        case readOnly
        case readWrite(create: Bool)
    }

    public init(path: String, mode: Mode) throws(IOError) {
        var flags: Int32
        switch mode {
            case .readOnly:
                flags = O_RDONLY | O_CLOEXEC
            case .readWrite(let create):
                flags = O_RDWR | O_CLOEXEC
                if create { flags |= O_CREAT }
        }
        let fd = path.withCString { unsafe open($0, flags, 0o644) }
        guard fd >= 0 else { throw IOError.capturingErrno("open(\(path))") }
        self.fileDescriptor = fd
        self.closeOnDeinit = true
    }

    /// Wraps an already-open descriptor (ownership not transferred).
    public init(borrowing fd: Int32) {
        self.fileDescriptor = fd
        self.closeOnDeinit = false
    }

    deinit {
        if closeOnDeinit { close() }
    }

    public func fileSize() throws(IOError) -> Int {
        var st = stat()
        guard unsafe fstat(fileDescriptor, &st) == 0 else { throw IOError.capturingErrno("fstat") }
        return Int(st.st_size)
    }

    public func pread(into buffer: UnsafeMutableRawBufferPointer, at offset: Int) throws(IOError) {
        guard let base = buffer.baseAddress else { return }  // empty buffer: nothing to read
        var done = 0
        while done < buffer.count {
            // Module-qualified to disambiguate the libc syscall from this type's own
            // `pread` method; the module name is the only thing that differs by platform.
            #if canImport(Darwin)
                let n = unsafe Darwin.pread(
                    fileDescriptor, base + done, buffer.count - done, off_t(offset + done))
            #else
                let n = unsafe Glibc.pread(
                    fileDescriptor, base + done, buffer.count - done, off_t(offset + done))
            #endif
            if n < 0 {
                if errno == EINTR { continue }
                throw IOError.capturingErrno("pread")
            }
            if n == 0 { throw IOError(errno: 0, op: "pread(short read at \(offset + done))") }
            done += n
        }
    }

    public func pwrite(_ buffer: UnsafeRawBufferPointer, at offset: Int) throws(IOError) {
        guard let base = buffer.baseAddress else { return }  // empty buffer: nothing to write
        var done = 0
        while done < buffer.count {
            #if canImport(Darwin)
                let n = unsafe Darwin.pwrite(
                    fileDescriptor, base + done, buffer.count - done, off_t(offset + done))
            #else
                let n = unsafe Glibc.pwrite(
                    fileDescriptor, base + done, buffer.count - done, off_t(offset + done))
            #endif
            if n < 0 {
                if errno == EINTR { continue }
                throw IOError.capturingErrno("pwrite")
            }
            // A zero-byte return for a non-empty request makes no forward progress; treat it as a
            // short write rather than spin forever (mirrors the `pread` short-read guard).
            if n == 0 { throw IOError(errno: 0, op: "pwrite(zero-length write at \(offset + done))") }
            done += n
        }
    }

    public func pwritev(_ buffers: [UnsafeRawBufferPointer], at offset: Int) throws(IOError) {
        var at = offset
        var index = 0
        #if canImport(Darwin)
            let iovCap = Int(IOV_MAX)
        #else
            let iovCap = 1024  // Linux UIO_MAXIOV; the Glibc Swift overlay doesn't surface IOV_MAX
        #endif
        while unsafe index < buffers.count {
            let count = unsafe min(buffers.count - index, iovCap)
            let batch = unsafe buffers[index ..< (index + count)]
            let total = unsafe batch.reduce(0) { $0 + $1.count }
            // Build the iovec batch in scratch storage (stack for typical fan-out, heap for large)
            // instead of allocating a fresh `[iovec]` per batch. `iovec` is trivial, so the temporary
            // needs no explicit deinitialization.
            let n = withUnsafeTemporaryAllocation(of: iovec.self, capacity: count) { iov -> Int in
                for k in 0 ..< count {
                    let buf = unsafe buffers[index + k]
                    unsafe iov.initializeElement(
                        at: k,
                        to: iovec(
                            iov_base: UnsafeMutableRawPointer(mutating: buf.baseAddress),
                            iov_len: buf.count))
                }
                #if canImport(Darwin)
                    return unsafe Darwin.pwritev(fileDescriptor, iov.baseAddress, Int32(count), off_t(at))
                #else
                    return unsafe Glibc.pwritev(fileDescriptor, iov.baseAddress, Int32(count), off_t(at))
                #endif
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw IOError.capturingErrno("pwritev")
            }
            if n != total {
                // Partial vectored write: finish the remainder element-wise.
                var skip = n
                var resumeAt = at + n
                for j in index ..< (index + count) {
                    let buf = unsafe buffers[j]
                    if skip >= buf.count {
                        skip -= buf.count
                        continue
                    }
                    let rest = unsafe UnsafeRawBufferPointer(rebasing: buf[skip...])
                    unsafe try pwrite(rest, at: resumeAt)
                    resumeAt += rest.count
                    skip = 0
                }
            }
            at += total
            index += count
        }
    }

    public func sync(_ profile: DurabilityProfile) throws(IOError) {
        switch profile {
            case .none:
                return
            case .barrier:
                #if canImport(Darwin)
                    if fcntl(fileDescriptor, F_BARRIERFSYNC) == -1 {
                        guard fsync(fileDescriptor) == 0 else {
                            throw IOError.capturingErrno("fsync(barrier fallback)")
                        }
                    }
                #else
                    // Linux has no `F_BARRIERFSYNC`. `fdatasync` is the closest analogue:
                    // it forces the data (and the size metadata needed to read it back)
                    // to the storage stack, which is the ordering guarantee the barrier
                    // profile relies on. It does not issue a device cache flush — that is
                    // exactly the barrier/full distinction Darwin draws.
                    guard fdatasync(fileDescriptor) == 0 else { throw IOError.capturingErrno("fdatasync(barrier)") }
                #endif
            case .full:
                #if canImport(Darwin)
                    if fcntl(fileDescriptor, F_FULLFSYNC) == -1 {
                        guard fsync(fileDescriptor) == 0 else { throw IOError.capturingErrno("fsync(full fallback)") }
                    }
                #else
                    // `F_FULLFSYNC` asks the drive to flush its cache; Linux exposes no
                    // portable userspace equivalent, so `fsync` is the strongest portable
                    // guarantee (already the Darwin fallback when `F_FULLFSYNC` is refused).
                    guard fsync(fileDescriptor) == 0 else { throw IOError.capturingErrno("fsync(full)") }
                #endif
        }
    }

    public func preallocate(minimumSize: Int) throws(IOError) {
        let current = try fileSize()
        guard minimumSize > current else { return }
        #if canImport(Darwin)
            var store = fstore_t(
                fst_flags: UInt32(F_ALLOCATECONTIG),
                fst_posmode: F_PEOFPOSMODE,
                fst_offset: 0,
                fst_length: off_t(minimumSize - current),
                fst_bytesalloc: 0)
            if unsafe fcntl(fileDescriptor, F_PREALLOCATE, &store) == -1 {
                store.fst_flags = UInt32(F_ALLOCATEALL)
                // Best effort: a failed preallocation only costs contiguity, not correctness.
                _ = unsafe fcntl(fileDescriptor, F_PREALLOCATE, &store)
            }
        #else
            // Linux equivalent: `posix_fallocate` reserves backing blocks for the
            // range. Like the Darwin `F_PREALLOCATE` hint it is a best-effort
            // optimization (avoids fragmentation / ENOSPC-at-write), not a
            // correctness requirement — the shared `ftruncate` below establishes the
            // actual file length post-condition. On filesystems that don't support it
            // `posix_fallocate` returns an error code, which we ignore.
            _ = posix_fallocate(fileDescriptor, off_t(current), off_t(minimumSize - current))
        #endif
        guard ftruncate(fileDescriptor, off_t(minimumSize)) == 0 else { throw IOError.capturingErrno("ftruncate") }
    }

    public func truncate(to size: Int) throws(IOError) {
        guard ftruncate(fileDescriptor, off_t(size)) == 0 else { throw IOError.capturingErrno("ftruncate") }
    }

    /// Toggles the unified-buffer-cache bypass for bulk load paths.
    public func setNoCache(_ enabled: Bool) {
        #if canImport(Darwin)
            _ = fcntl(fileDescriptor, F_NOCACHE, enabled ? 1 : 0)
        #else
            // Linux has no persistent per-fd "no cache" mode. The closest best-effort
            // is to advise the page cache to drop this file's pages when bypass is
            // requested (`POSIX_FADV_DONTNEED` over the whole file, len 0 = to EOF),
            // and to restore the default policy otherwise. Purely advisory: any error
            // (e.g. ENOSYS on exotic filesystems) is ignored, exactly like the Darwin
            // `fcntl` whose result is discarded.
            _ = posix_fadvise(
                fileDescriptor, 0, 0, enabled ? POSIX_FADV_DONTNEED : POSIX_FADV_NORMAL)
        #endif
    }

    public func close() {
        guard fileDescriptor >= 0 else { return }
        let (exchanged, _) = closed.compareExchange(
            expected: false, desired: true, ordering: .acquiringAndReleasing)
        // Module-qualified to call the libc syscall, not this type's `close`.
        #if canImport(Darwin)
            if exchanged { _ = Darwin.close(fileDescriptor) }
        #else
            if exchanged { _ = Glibc.close(fileDescriptor) }
        #endif
    }
}

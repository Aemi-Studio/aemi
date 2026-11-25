import Synchronization

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

/// An RAII POSIX `flock(2)` advisory file lock built on ``PosixFile``.
///
/// The lock is held for the lifetime of the instance (or until ``release()`` is called) and is
/// automatically released when the underlying file descriptor closes in `deinit` or on process
/// exit. Uses `O_CLOEXEC` via ``PosixFile`` so child processes never inherit the lock descriptor.
///
/// Stdlib + platform libc only; no Foundation.
public final class FileLock: Sendable {
    /// Lock acquisition mode.
    public enum Mode: Sendable, Equatable {
        /// Exclusive lock (`LOCK_EX`), blocking until available.
        case exclusive
        /// Exclusive lock (`LOCK_EX | LOCK_NB`), failing immediately with `EWOULDBLOCK` if held.
        case exclusiveNonBlocking
        /// Shared lock (`LOCK_SH`), blocking until available.
        case shared
        /// Shared lock (`LOCK_SH | LOCK_NB`), failing immediately with `EWOULDBLOCK` if exclusively held.
        case sharedNonBlocking

        var flockOperation: Int32 {
            switch self {
                case .exclusive: LOCK_EX
                case .exclusiveNonBlocking: LOCK_EX | LOCK_NB
                case .shared: LOCK_SH
                case .sharedNonBlocking: LOCK_SH | LOCK_NB
            }
        }
    }

    private let file: PosixFile
    private let released = Atomic<Bool>(false)

    /// Opens (creating if needed) `path` and acquires an advisory lock in `mode`.
    ///
    /// Retries `EINTR` automatically when blocking. Throws ``IOError`` (with `errno == EWOULDBLOCK`
    /// or `EAGAIN` when a non-blocking lock is already held by another open file description).
    public init(path: String, mode: Mode = .exclusiveNonBlocking) throws(IOError) {
        let opened = try PosixFile(path: path, mode: .readWrite(create: true))
        let op = mode.flockOperation
        while true {
            if flock(opened.fileDescriptor, op) == 0 {
                self.file = opened
                return
            }
            let code = errno
            if code == EINTR { continue }
            opened.close()
            throw IOError(errno: code, op: "flock(\(path))")
        }
    }

    /// Explicitly unlocks and closes the descriptor. Safe to call more than once.
    public func release() {
        let (exchanged, _) = released.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing)
        guard exchanged else { return }
        _ = flock(file.fileDescriptor, LOCK_UN)
        file.close()
    }

    deinit {
        release()
    }

    /// Acquires a lock on `path`, runs `body`, and releases the lock before returning.
    public static func withLock<R>(
        at path: String,
        mode: Mode = .exclusive,
        _ body: () throws -> R
    ) throws -> R {
        let lock = try FileLock(path: path, mode: mode)
        defer { lock.release() }
        return try body()
    }
}

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// A failed POSIX operation, carrying the captured `errno` and a short label for
/// the syscall that produced it. Domain-neutral: a consumer that needs a richer
/// error taxonomy (e.g. a database error enum) maps this at its own boundary,
/// preserving `errno` and `op` verbatim.
public struct IOError: Error, Equatable, Sendable {
    /// The C `errno` captured at the failure site.
    public let errno: Int32
    /// A short label for the operation that failed (e.g. `"pread"`, `"mmap"`).
    public let op: String

    public init(errno: Int32, op: String) {
        self.errno = errno
        self.op = op
    }
}

extension IOError: CustomStringConvertible {
    public var description: String {
        // Format `errno` into a caller-owned buffer so concurrent formatting can't corrupt a shared
        // static buffer (as plain `strerror` would). Both Darwin and Swift's Glibc module expose the
        // XSI `strerror_r` (returns 0 on success and fills the buffer) — the GNU `char *`-returning
        // variant is NOT what the importer vends on the family's pinned Linux toolchain — so a single
        // branch serves both platforms. The buffer is zero-initialized first so no path can ever read
        // uninitialized stack memory.
        let detail = withUnsafeTemporaryAllocation(of: CChar.self, capacity: 256) { buffer in
            guard let base = buffer.baseAddress else { return "errno \(errno)" }
            unsafe base.initialize(repeating: 0, count: buffer.count)
            // On failure don't trust a partially written buffer — surface the bare errno instead.
            guard unsafe strerror_r(errno, base, buffer.count) == 0 else { return "errno \(errno)" }
            return unsafe String(cString: base)
        }
        return "I/O error in \(op): \(detail) (errno \(errno))"
    }
}

extension IOError {
    /// Builds an ``IOError`` capturing the current global `errno`. Use it at the `throw` site immediately
    /// after a failing syscall, before any other call can overwrite `errno`. The platform `errno` is
    /// module-qualified: inside this type's scope the struct's own `errno` property would shadow it.
    static func capturingErrno(_ op: String) -> IOError {
        #if canImport(Darwin)
            return IOError(errno: Darwin.errno, op: op)
        #elseif canImport(Glibc)
            return IOError(errno: Glibc.errno, op: op)
        #endif
    }
}

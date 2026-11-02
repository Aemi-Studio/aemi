#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

/// Replaces a file's contents so that a reader, or a crash, sees either the old contents or the new, never a mix.
///
/// The new contents go to a file beside the target (same directory, so the same volume), created exclusively; it is
/// synced, renamed over the target, and the directory is synced, so the rename itself is durable. Foundation's
/// `.atomic` writes skip the directory sync: after a power loss the target can come back with its old contents, or
/// missing, though the call had returned.
public enum AtomicFile {
    /// Replaces `path` with `bytes`.
    /// - Parameters:
    ///   - path: the file to replace or create.
    ///   - bytes: its new contents.
    ///   - durability: how the file and its directory are synced; `.none` keeps the atomicity, not the durability.
    ///   - permissions: the new file's mode bits.
    /// - Throws: the first failing call's ``IOError``; the temporary file is removed and `path` is left as it was.
    public static func replace(
        at path: String,
        with bytes: [UInt8],
        durability: DurabilityProfile = .full,
        permissions: UInt16 = 0o644
    ) throws(IOError) {
        let (directory, name) = split(path)
        var random = SystemRandomNumberGenerator()
        let suffix = String(random.next() as UInt64, radix: 16)
        let temporary = "\(directory)/.\(name).\(suffix).tmp"
        do throws(IOError) {
            let file = try PosixFile(creatingExclusively: temporary, permissions: permissions)
            try file.write(bytes, at: 0)
            try file.sync(durability)
            file.close()
            let renamed = temporary.withCString { from in path.withCString { to in unsafe rename(from, to) } }
            guard renamed == 0 else { throw IOError.capturingErrno("rename(\(temporary), \(path))") }
        } catch {
            _ = temporary.withCString { unsafe unlink($0) }
            throw error
        }
        try syncDirectory(directory, durability)
    }

    /// Syncs a directory's entries (a rename or a creation in it) to storage.
    public static func syncDirectory(_ directory: String, _ durability: DurabilityProfile) throws(IOError) {
        guard durability != .none else { return }
        let descriptor = directory.withCString { unsafe open($0, O_RDONLY | O_CLOEXEC | O_DIRECTORY) }
        guard descriptor >= 0 else { throw IOError.capturingErrno("open(\(directory), directory)") }
        defer { _ = close(descriptor) }
        try PosixFile(borrowing: descriptor).sync(durability)
    }

    /// The directory (`.` when there is none) and the last component of `path`.
    static func split(_ path: String) -> (directory: String, name: String) {
        guard let slash = path.lastIndex(of: "/") else { return (".", path) }
        let directory = slash == path.startIndex ? "/" : String(path[..<slash])
        return (directory, String(path[path.index(after: slash)...]))
    }
}

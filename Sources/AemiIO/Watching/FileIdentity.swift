#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Which file a path names, and which version of it: the device and inode it lives at, its size, and when it was last
/// written. A file replaced by an atomic save is a new inode; one written in place keeps its inode and changes its size
/// or time. Cheap: one `realpath` and one `stat`, never the contents.
public struct FileIdentity: Sendable, Hashable {
    /// The file's real path, with symlinks resolved.
    public let path: String
    public let device: UInt64
    public let inode: UInt64
    public let size: Int64
    /// The last write, in seconds and nanoseconds since 1970.
    public let modifiedSeconds: Int64
    public let modifiedNanoseconds: Int64

    /// The file at `path` now, or nil when it does not exist or cannot be examined.
    public init?(path: String) {
        guard let real = unsafe realpath(path, nil) else { return nil }
        defer { unsafe free(real) }
        let resolved = unsafe String(cString: real)
        var info = stat()
        guard unsafe stat(resolved, &info) == 0 else { return nil }
        self.path = resolved
        device = UInt64(truncatingIfNeeded: info.st_dev)
        inode = UInt64(truncatingIfNeeded: info.st_ino)
        size = Int64(info.st_size)
        #if canImport(Darwin)
            modifiedSeconds = Int64(info.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(info.st_mtimespec.tv_nsec)
        #else
            modifiedSeconds = Int64(info.st_mtim.tv_sec)
            modifiedNanoseconds = Int64(info.st_mtim.tv_nsec)
        #endif
    }

    /// Whether `other` is the same file, whatever was written to it since: same device and inode.
    public func isSameFile(as other: FileIdentity) -> Bool {
        device == other.device && inode == other.inode
    }
}

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

/// Copies one regular file, by cloning where the file system can (APFS `clonefile`: metadata only, the blocks are
/// shared until either side writes), and by reading and writing otherwise.
public enum FileCopy {
    /// How a copy was made.
    public enum Method: Sendable, Equatable {
        /// A copy-on-write clone; no data was read or written.
        case cloned
        /// The bytes were read and written.
        case copied
    }

    /// Copies the regular file `source` to `destination`, which must not exist, keeping the mode bits.
    ///
    /// A link at `source` is refused (`ELOOP`), as is anything but a regular file (`EINVAL`); a link or file at
    /// `destination` is refused (`EEXIST`). On failure nothing is left at `destination`.
    @discardableResult
    public static func copy(from source: String, to destination: String) throws(IOError) -> Method {
        var info = stat()
        guard source.withCString({ unsafe lstat($0, &info) }) == 0 else {
            throw IOError.capturingErrno("lstat(\(source))")
        }
        let type = info.st_mode & S_IFMT
        if type == S_IFLNK { throw IOError(errno: ELOOP, op: "copy(\(source)): a link") }
        guard type == S_IFREG else { throw IOError(errno: EINVAL, op: "copy(\(source)): not a regular file") }
        #if canImport(Darwin)
            let cloned = source.withCString { from in
                destination.withCString { to in unsafe clonefile(from, to, UInt32(CLONE_NOFOLLOW)) }
            }
            if cloned == 0 { return .cloned }
            // Another volume, or a file system without clones: copy the bytes. Anything else is an answer.
            guard errno == ENOTSUP || errno == EXDEV || errno == EOPNOTSUPP else {
                throw IOError.capturingErrno("clonefile(\(source), \(destination))")
            }
        #endif
        try copyBytes(from: source, to: destination, permissions: UInt16(info.st_mode & 0o7777))
        return .copied
    }

    /// The read-and-write copy, into a file created exclusively.
    static func copyBytes(from source: String, to destination: String, permissions: UInt16) throws(IOError) {
        let input = source.withCString { unsafe open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
        guard input >= 0 else { throw IOError.capturingErrno("open(\(source))") }
        defer { _ = close(input) }
        let output = try PosixFile(creatingExclusively: destination, permissions: permissions)
        do throws(IOError) {
            let reader = PosixFile(borrowing: input)
            let size = try reader.fileSize()
            var offset = 0
            let chunk = 1 << 20
            while offset < size {
                let bytes = try reader.read(at: offset, count: min(chunk, size - offset))
                try output.write(bytes, at: offset)
                offset += bytes.count
            }
        } catch {
            output.close()
            _ = destination.withCString { unsafe unlink($0) }
            throw error
        }
    }
}

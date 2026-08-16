import Foundation
// `public import`: `TemporaryDirectory.filePath(_:)` returns a swift-system `FilePath` in its public
// signature, so under `InternalImportsByDefault` the module must be imported publicly.
public import SystemPackage

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Creates a fresh private temp directory and vends paths inside it. The directory is
/// made with `mkdtemp` — an atomic, race-free syscall that creates a uniquely-named
/// `0700` directory in a single step (no TOCTOU window, owner-only permissions). Paths
/// are joined through swift-system's `FilePath` (correct separator handling), and
/// teardown is one safe, recursive `FileManager.removeItem`.
///
/// This replaces the former hand-rolled cleanup, which walked the directory stream and
/// read each `dirent`'s `d_name` through a raw pointer — ASan-fragile, and silently
/// **leaking** any subdirectory because a bare `unlink` cannot remove one (so the final
/// `rmdir` then failed). The recursive `removeItem` fixes both.
public struct TemporaryDirectory: Sendable {
    /// The directory path, as a `String` — the form the AD-family's many existing call
    /// sites already pass around.
    public let path: String

    public init(prefix: String = "adtestkit") {
        // `mkdtemp` mutates the template in place, replacing the trailing `XXXXXX` with
        // the unique suffix and creating the 0700 directory atomically.
        let template = FilePath(NSTemporaryDirectory()).appending("\(prefix).XXXXXX").string
        var buffer = Array(template.utf8CString)
        let created = buffer.withUnsafeMutableBufferPointer { mkdtemp($0.baseAddress!) != nil }
        precondition(created, "TemporaryDirectory: mkdtemp failed (\(Errno(rawValue: errno)))")
        self.path = String(decoding: buffer.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// A path to `name` inside this directory, as a `String` (joined via `FilePath`).
    public func file(_ name: String) -> String { FilePath(path).appending(name).string }

    /// A path to `name` inside this directory, as a typed swift-system `FilePath`.
    public func filePath(_ name: String) -> FilePath { FilePath(path).appending(name) }

    /// Best-effort recursive teardown: removes the directory and everything inside it in
    /// one safe `FileManager` call. A missing directory is not an error.
    public func cleanup() {
        try? FileManager.default.removeItem(atPath: path)
    }
}

extension TemporaryDirectory {
    /// Creates a `TemporaryDirectory`, runs `body` with it, and cleans up afterward — even if
    /// `body` throws.
    public static func withTemporaryDirectory<R>(
        prefix: String = "adtestkit", _ body: (TemporaryDirectory) throws -> R
    ) rethrows -> R {
        let dir = TemporaryDirectory(prefix: prefix)
        defer { dir.cleanup() }
        return try body(dir)
    }
}

/// Vends a unique scratch file path inside a fresh private `TemporaryDirectory`, runs `body`, then
/// removes the **entire** private directory. Because the file lives in its own
/// directory, that single removal also clears any `-wal` / `-shm` / `-lock` engine
/// siblings the caller drops next to it — no hard-coded suffix list required. Replaces
/// the two ADDB `withTemporaryFilePath` re-rolls and apple-docs' ad-hoc temp handling.
public func withTemporaryFilePath<R>(
    prefix: String = "adtestkit",
    extension ext: String = "db",
    _ body: (String) throws -> R
) rethrows -> R {
    let dir = TemporaryDirectory(prefix: prefix)
    defer { dir.cleanup() }
    return try body(dir.file("\(prefix).\(ext)"))
}

// MARK: - Back-compatibility (deprecated, renamed)

@available(*, deprecated, renamed: "TemporaryDirectory")
public typealias TempDir = TemporaryDirectory

extension TemporaryDirectory {
    @available(*, deprecated, renamed: "withTemporaryDirectory(prefix:_:)")
    public static func withTempDir<R>(
        prefix: String = "adtestkit", _ body: (TemporaryDirectory) throws -> R
    ) rethrows -> R {
        try withTemporaryDirectory(prefix: prefix, body)
    }
}

@available(*, deprecated, renamed: "withTemporaryFilePath(prefix:extension:_:)")
public func withTempPath<R>(
    prefix: String = "adtestkit",
    extension ext: String = "db",
    _ body: (String) throws -> R
) rethrows -> R {
    try withTemporaryFilePath(prefix: prefix, extension: ext, body)
}

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Canonical spellings of paths, as the kernel reports them: every symlink resolved, so `/tmp/a` is `/private/tmp/a`
/// on Apple platforms. Watchers key what they watch by these.
public enum CanonicalPath {
    /// `path` with its symlinks resolved by `realpath(3)` as far as it exists, and its missing components appended as
    /// given, so a file not created yet canonicalizes too. A path no prefix of which resolves comes back unchanged.
    /// - Complexity: One `realpath` call per missing trailing component, plus one.
    public static func of(_ path: String) -> String {
        var end = path.endIndex
        var missing: [Substring] = []
        while true {
            let prefix = path[..<end]
            if let resolved = resolved(prefix.isEmpty ? "." : String(prefix)) {
                return missing.reversed().reduce(resolved) { joined($0, $1) }
            }
            guard let slash = prefix.lastIndex(of: "/") else {
                // A relative path: the missing components then hang off the working directory.
                guard !prefix.isEmpty else { return path }
                missing.append(prefix)
                end = prefix.startIndex
                continue
            }
            let parentEnd = slash == path.startIndex ? path.index(after: slash) : slash
            guard parentEnd < end else { return path }
            let component = path[path.index(after: slash) ..< end]
            if !component.isEmpty {
                missing.append(component)
            }
            end = parentEnd
        }
    }

    /// The canonical paths a watched file's events arrive under: its target, and also the link's own location when
    /// `path` is a symlink, since an atomic save through the link replaces the link.
    public static func keys(forFile path: String) -> [String] {
        let target = of(path)
        let location = joined(of(parent(of: path)), Substring(lastComponent(of: path)))
        return target == location ? [target] : [target, location]
    }

    /// `path` up to its last `/`: `/` for a top-level path, `.` for a bare name.
    static func parent(of path: String) -> String {
        let trimmed = trimmingTrailingSlashes(path)
        guard let slash = trimmed.lastIndex(of: "/") else { return "." }
        return slash == trimmed.startIndex ? "/" : String(trimmed[..<slash])
    }

    /// Whether `path` is `directory` or lies below it, comparing bytes along whole components.
    static func isInside(_ path: String, _ directory: String) -> Bool {
        let pathBytes = path.utf8
        let directoryBytes = directory.utf8
        guard pathBytes.starts(with: directoryBytes) else { return false }
        if directoryBytes.last == UInt8(ascii: "/") { return true }
        let rest = pathBytes.dropFirst(directoryBytes.count)
        return rest.isEmpty || rest.first == UInt8(ascii: "/")
    }

    /// The fewest of `directories` that still cover every one of them, sorted.
    /// - Complexity: O(n²) in the directories.
    static func minimalCover(_ directories: some Sequence<String>) -> [String] {
        var cover: [String] = []
        for directory in Set(directories).sorted(by: { $0.utf8.count < $1.utf8.count })
        where !cover.contains(where: { isInside(directory, $0) }) {
            cover.append(directory)
        }
        return cover.sorted()
    }

    /// The nearest of `path`'s ancestors that exists as a directory: where its next missing component will appear.
    /// `/` at worst.
    static func deepestExistingDirectory(above path: String) -> String {
        var candidate = parent(of: path)
        while candidate != "/", candidate != ".", !isDirectory(candidate) {
            candidate = parent(of: candidate)
        }
        return candidate
    }

    /// Whether `path` names a directory, following symlinks.
    static func isDirectory(_ path: String) -> Bool {
        var info = stat()
        guard unsafe stat(path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFDIR
    }

    static func joined(_ base: String, _ component: Substring) -> String {
        base.hasSuffix("/") ? base + component : base + "/" + component
    }

    static func lastComponent(of path: String) -> Substring {
        let trimmed = trimmingTrailingSlashes(path)
        guard let slash = trimmed.lastIndex(of: "/") else { return trimmed }
        return trimmed[trimmed.index(after: slash)...]
    }

    /// `realpath(3)` of `path`, or nil when a component is missing or unreadable.
    private static func resolved(_ path: String) -> String? {
        // `realpath` returns a `malloc`ed buffer, freed here once copied into the `String`.
        guard let buffer = unsafe realpath(path, nil) else { return nil }
        defer { unsafe free(buffer) }
        return unsafe String(cString: buffer)
    }

    private static func trimmingTrailingSlashes(_ path: String) -> Substring {
        var trimmed = Substring(path)
        while trimmed.count > 1, trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return trimmed
    }
}

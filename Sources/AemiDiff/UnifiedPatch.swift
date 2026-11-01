/// A unified diff or git patch, parsed into per-file hunks.
///
/// Handles `git format-patch` / `git diff` output (with `diff --git`, `rename from/to`, `new file mode`,
/// `deleted file mode`, binary markers) and plain unified diffs that start at `---` / `+++`.
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
public struct UnifiedPatch: Sendable, Equatable {
    public struct Hunk: Sendable, Equatable {
        public enum LineKind: Sendable, Equatable {
            case context, removed, added
        }

        public struct Line: Sendable, Equatable {
            public let kind: LineKind
            public let text: String

            public init(kind: LineKind, text: String) {
                self.kind = kind
                self.text = text
            }
        }

        public let oldStart: Int
        public let oldCount: Int
        public let newStart: Int
        public let newCount: Int
        public var lines: [Line]

        public init(oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, lines: [Line] = []) {
            self.oldStart = oldStart
            self.oldCount = oldCount
            self.newStart = newStart
            self.newCount = newCount
            self.lines = lines
        }
    }

    public struct FileChange: Sendable, Equatable {
        /// Path before the change; nil for an added file.
        public var oldPath: String?
        /// Path after the change; nil for a deleted file.
        public var newPath: String?
        public var hunks: [Hunk]
        public var isBinary: Bool

        public init(oldPath: String?, newPath: String?, hunks: [Hunk] = [], isBinary: Bool = false) {
            self.oldPath = oldPath
            self.newPath = newPath
            self.hunks = hunks
            self.isBinary = isBinary
        }

        public var isRename: Bool {
            guard let oldPath, let newPath else { return false }
            return oldPath != newPath
        }

        /// The old and new documents as far as the patch carries them: hunk lines at their real line numbers,
        /// lines the patch does not include left blank, nil for a side that does not exist.
        public var reconstructedTexts: (old: String?, new: String?) {
            var old: [String] = []
            var new: [String] = []
            for hunk in hunks {
                while old.count < hunk.oldStart - 1 { old.append("") }
                while new.count < hunk.newStart - 1 { new.append("") }
                for line in hunk.lines {
                    switch line.kind {
                        case .context:
                            old.append(line.text)
                            new.append(line.text)
                        case .removed:
                            old.append(line.text)
                        case .added:
                            new.append(line.text)
                    }
                }
            }
            func text(_ lines: [String]) -> String { lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n" }
            return (oldPath == nil ? nil : text(old), newPath == nil ? nil : text(new))
        }
    }

    public private(set) var files: [FileChange]

    public init(files: [FileChange]) {
        self.files = files
    }

    /// Parses patch text. Unknown lines are skipped, so mail headers and commit messages around a patch are fine.
    /// - Complexity: O(n) in the number of lines.
    public init(parsing text: String) {
        var files: [FileChange] = []
        var current: FileChange?
        var hunk: Hunk?
        var remainingOld = 0
        var remainingNew = 0
        var seenHeaderPaths = false

        func closeHunk() {
            if let open = hunk, current != nil { current?.hunks.append(open) }
            hunk = nil
        }
        func closeFile() {
            closeHunk()
            if let file = current { files.append(file) }
            current = nil
            seenHeaderPaths = false
        }

        /// Consumes one line of the open hunk's body; false once the hunk is complete or the line is not body.
        func consumeHunkLine(_ line: Substring) -> Bool {
            guard hunk != nil, remainingOld > 0 || remainingNew > 0 else { return false }
            if line.hasPrefix("\\ ") { return true }
            let first = line.utf8.first
            let kind: Hunk.LineKind? =
                switch first {
                    case UInt8(ascii: " "): .context
                    case UInt8(ascii: "-"): .removed
                    case UInt8(ascii: "+"): .added
                    case nil: .context
                    default: nil
                }
            guard let kind else { return false }
            hunk?.lines.append(Hunk.Line(kind: kind, text: first == nil ? "" : String(line.dropFirst())))
            if kind != .added { remainingOld -= 1 }
            if kind != .removed { remainingNew -= 1 }
            return true
        }
        /// Applies a file or hunk header line; anything else is skipped.
        func applyHeader(_ line: Substring) {
            if line.hasPrefix("diff --git ") {
                closeFile()
                let (old, new) = Self.gitHeaderPaths(String(line.dropFirst("diff --git ".count)))
                current = FileChange(oldPath: old, newPath: new)
            } else if line.hasPrefix("@@ ") {
                closeHunk()
                if current == nil { current = FileChange(oldPath: nil, newPath: nil) }
                let header = Self.hunkHeader(line)
                hunk = header
                remainingOld = header.oldCount
                remainingNew = header.newCount
            } else if line.hasPrefix("--- ") {
                closeHunk()
                if current == nil || seenHeaderPaths {
                    closeFile()
                    current = FileChange(oldPath: nil, newPath: nil)
                }
                current?.oldPath = Self.headerPath(line.dropFirst(4), stripping: "a/")
                seenHeaderPaths = true
            } else if line.hasPrefix("+++ ") {
                closeHunk()
                if current == nil { current = FileChange(oldPath: nil, newPath: nil) }
                current?.newPath = Self.headerPath(line.dropFirst(4), stripping: "b/")
            } else if line.hasPrefix("rename from ") || line.hasPrefix("copy from ") {
                current?.oldPath = Self.renamePath(line)
            } else if line.hasPrefix("rename to ") || line.hasPrefix("copy to ") {
                current?.newPath = Self.renamePath(line)
            } else if line.hasPrefix("new file mode") {
                current?.oldPath = nil
            } else if line.hasPrefix("deleted file mode") {
                current?.newPath = nil
            } else if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
                current?.isBinary = true
            }
        }

        for slice in text.utf8.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false) {
            let line = Substring(slice.last == UInt8(ascii: "\r") ? slice.dropLast() : slice)
            if consumeHunkLine(line) { continue }
            if hunk != nil, line.isEmpty || line.hasPrefix("\\ ") { continue }
            applyHeader(line)
        }
        closeFile()
        self.files = files.filter { $0.oldPath != nil || $0.newPath != nil }
    }

    /// Splits `a/x b/y` into both paths; paths with spaces are matched on the `a/` `b/` prefixes.
    private static func gitHeaderPaths(_ rest: String) -> (String?, String?) {
        let isBlank = { (character: Character) in character.isWhitespace && !character.isNewline }
        var unquoted = Substring(rest)
        while let first = unquoted.first, isBlank(first) { unquoted.removeFirst() }
        while let last = unquoted.last, isBlank(last) { unquoted.removeLast() }
        if let range = unquoted.ranges(of: " b/").last {
            let old = String(unquoted[unquoted.startIndex ..< range.lowerBound])
            let new = String(unquoted[range.upperBound...])
            return (old.hasPrefix("a/") ? String(old.dropFirst(2)) : old, new)
        }
        let parts = unquoted.split(separator: " ", maxSplits: 1).map(String.init)
        return (parts.first, parts.count > 1 ? parts[1] : parts.first)
    }

    /// The path after the two-word verb of a `rename from`, `rename to`, `copy from` or `copy to` line.
    private static func renamePath(_ line: Substring) -> String {
        String(line.drop(while: { $0 != " " }).dropFirst().drop(while: { $0 != " " }).dropFirst())
    }

    private static func headerPath(_ rest: Substring, stripping prefix: String) -> String? {
        var path = rest.split(separator: "\t", maxSplits: 1).first.map(String.init) ?? ""
        if path.hasPrefix("\"") && path.hasSuffix("\"") && path.count >= 2 {
            path = String(path.dropFirst().dropLast())
        }
        if path == "/dev/null" { return nil }
        if path.hasPrefix(prefix) { path.removeFirst(prefix.count) }
        return path
    }

    /// The largest line number a hunk header may name; beyond it the header is treated as malformed rather than
    /// letting the reconstruction pad a document with that many empty lines.
    public static let maximumLineNumber = 1 << 22

    private static func hunkHeader(_ line: Substring) -> Hunk {
        func range(_ token: Substring) -> (Int, Int) {
            let parts = token.dropFirst().split(separator: ",", maxSplits: 1)
            let start = min(max(Int(parts.first ?? "") ?? 0, 0), maximumLineNumber)
            let count = min(max(parts.count > 1 ? Int(parts[1]) ?? 1 : 1, 0), maximumLineNumber)
            return (start, count)
        }
        let tokens = line.dropFirst(3).split(separator: " ", maxSplits: 2)
        let old = tokens.first.map(range) ?? (0, 0)
        let new = tokens.count > 1 ? range(tokens[1]) : (0, 0)
        return Hunk(oldStart: old.0, oldCount: old.1, newStart: new.0, newCount: new.1)
    }
}

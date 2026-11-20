/// A unified diff or git patch, parsed into per-file hunks.
///
/// Handles `git format-patch` / `git diff` output (with `diff --git`, `rename from/to`, `new file mode`,
/// `deleted file mode`, `old mode` / `new mode`, `index`, binary markers, `\ No newline at end of file`, paths git
/// quotes with C escapes), a merge's combined diff (`diff --cc`, read against its first parent), and plain unified
/// diffs that start at `---` / `+++`.
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
        /// The octal file modes git records (`100644`, `100755`, `120000`, `160000`), from `old mode`, `new mode`,
        /// `new file mode`, `deleted file mode` or the `index` line; nil when the patch names none.
        public var oldMode: String?
        public var newMode: String?
        /// The abbreviated object ids of the `index` line; nil when the patch has none.
        public var oldObjectID: String?
        public var newObjectID: String?
        /// Whether the side's last line has no line break, as `\ No newline at end of file` says.
        public var oldLacksFinalNewline = false
        public var newLacksFinalNewline = false
        /// Whether the change is one side of a merge's combined diff (`diff --cc`), read against the first parent.
        public var isCombined = false

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
            func text(_ lines: [String], lacksFinalNewline: Bool) -> String {
                lines.isEmpty ? "" : lines.joined(separator: "\n") + (lacksFinalNewline ? "" : "\n")
            }
            return (
                oldPath == nil ? nil : text(old, lacksFinalNewline: oldLacksFinalNewline),
                newPath == nil ? nil : text(new, lacksFinalNewline: newLacksFinalNewline)
            )
        }
    }

    public private(set) var files: [FileChange]

    public init(files: [FileChange]) {
        self.files = files
    }

    /// Parses patch text. Unknown lines are skipped, so mail headers and commit messages around a patch are fine.
    /// - Complexity: O(n) in the number of lines.
    public init(parsing text: String) {
        var parser = UnifiedPatchParser()
        for slice in text.utf8.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false) {
            parser.consume(Substring(slice.last == UInt8(ascii: "\r") ? slice.dropLast() : slice))
        }
        self.files = parser.finish()
    }

    /// The largest line number a hunk header may name; beyond it the header is treated as malformed rather than
    /// letting the reconstruction pad a document with that many empty lines.
    public static let maximumLineNumber = 1 << 22
}

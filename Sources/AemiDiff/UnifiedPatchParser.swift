/// The state of a ``UnifiedPatch`` being read line by line: the file and hunk open, and what the next lines count
/// towards.
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
struct UnifiedPatchParser {
    typealias FileChange = UnifiedPatch.FileChange
    typealias Hunk = UnifiedPatch.Hunk

    private var files: [FileChange] = []
    private var current: FileChange?
    private var hunk: Hunk?
    private var remainingOld = 0
    private var remainingNew = 0
    private var seenHeaderPaths = false
    /// The kind of the open hunk's last line, which a `\ No newline at end of file` line speaks of.
    private var lastKind: Hunk.LineKind?
    /// The parents of a combined diff's file: one prefix column each.
    private var parents = 1

    /// Reads one line, its line break removed.
    mutating func consume(_ line: Substring) {
        if consumeHunkLine(line) { return }
        if hunk != nil, line.hasPrefix("\\ ") {
            markMissingNewline()
            return
        }
        if hunk != nil, line.isEmpty { return }
        if !applyFileHeader(line) { applyHeader(line) }
    }

    /// The files read, once every line is consumed: those with at least one path.
    mutating func finish() -> [FileChange] {
        closeFile()
        return files.filter { $0.oldPath != nil || $0.newPath != nil }
    }

    private mutating func closeHunk() {
        if let open = hunk, current != nil { current?.hunks.append(open) }
        hunk = nil
        lastKind = nil
    }

    private mutating func closeFile() {
        closeHunk()
        if let file = current { files.append(file) }
        current = nil
        seenHeaderPaths = false
        parents = 1
    }

    /// A `\ No newline at end of file` line: the open hunk's last line ends its side, or both for context.
    private mutating func markMissingNewline() {
        switch lastKind {
            case .removed?: current?.oldLacksFinalNewline = true
            case .added?: current?.newLacksFinalNewline = true
            case .context?:
                current?.oldLacksFinalNewline = true
                current?.newLacksFinalNewline = true
            case nil: break
        }
    }

    /// Consumes one line of the open hunk's body; false once the hunk is complete or the line is not body.
    private mutating func consumeHunkLine(_ line: Substring) -> Bool {
        guard hunk != nil, remainingOld > 0 || remainingNew > 0 else { return false }
        if line.hasPrefix("\\ ") {
            markMissingNewline()
            return true
        }
        if parents > 1 { return consumeCombinedLine(line) }
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
        append(Hunk.Line(kind: kind, text: first == nil ? "" : String(line.dropFirst())))
        return true
    }

    /// One line of a combined diff, read against the first parent: a line the merge result holds is context or
    /// added as the first column says; one only the first parent holds is removed; one only another parent holds is
    /// skipped, as it is in neither side of this reading.
    private mutating func consumeCombinedLine(_ line: Substring) -> Bool {
        let columns = Array(line.utf8.prefix(parents))
        let marks: Set<UInt8> = [UInt8(ascii: " "), UInt8(ascii: "-"), UInt8(ascii: "+")]
        guard columns.count == parents || line.isEmpty, columns.allSatisfy(marks.contains) else { return false }
        let text = String(String.UnicodeScalarView(line.unicodeScalars.dropFirst(columns.count)))
        if !columns.contains(UInt8(ascii: "-")) {
            append(Hunk.Line(kind: columns.first == UInt8(ascii: "+") ? .added : .context, text: text))
        } else if columns.first == UInt8(ascii: "-") {
            append(Hunk.Line(kind: .removed, text: text))
        }
        return true
    }

    private mutating func append(_ line: Hunk.Line) {
        hunk?.lines.append(line)
        lastKind = line.kind
        if line.kind != .added { remainingOld -= 1 }
        if line.kind != .removed { remainingNew -= 1 }
    }

    /// Applies a line that opens a file or a hunk; false for any other line.
    private mutating func applyFileHeader(_ line: Substring) -> Bool {
        if line.hasPrefix("diff --git ") {
            closeFile()
            let (old, new) = UnifiedPatch.gitHeaderPaths(String(line.dropFirst("diff --git ".count)))
            current = FileChange(oldPath: old, newPath: new)
        } else if line.hasPrefix("diff --cc ") || line.hasPrefix("diff --combined ") {
            closeFile()
            let path = UnifiedPatch.unquoted(UnifiedPatch.renamePath(line))
            current = FileChange(oldPath: path, newPath: path)
            current?.isCombined = true
        } else if line.hasPrefix("@@@") {
            closeHunk()
            guard current?.isCombined == true, let header = UnifiedPatch.combinedHunkHeader(line) else { return true }
            parents = header.parents
            open(header.hunk)
        } else if line.hasPrefix("@@ ") {
            closeHunk()
            if current == nil { current = FileChange(oldPath: nil, newPath: nil) }
            open(UnifiedPatch.hunkHeader(line))
        } else {
            return false
        }
        return true
    }

    private mutating func open(_ header: Hunk) {
        hunk = header
        remainingOld = header.oldCount
        remainingNew = header.newCount
    }

    /// Applies a file's extended header or path line; anything else is skipped.
    private mutating func applyHeader(_ line: Substring) {
        if line.hasPrefix("--- ") {
            closeHunk()
            if current == nil || seenHeaderPaths {
                closeFile()
                current = FileChange(oldPath: nil, newPath: nil)
            }
            current?.oldPath = UnifiedPatch.headerPath(line.dropFirst(4), stripping: "a/")
            seenHeaderPaths = true
        } else if line.hasPrefix("+++ ") {
            closeHunk()
            if current == nil { current = FileChange(oldPath: nil, newPath: nil) }
            current?.newPath = UnifiedPatch.headerPath(line.dropFirst(4), stripping: "b/")
        } else {
            applyExtendedHeader(line)
        }
    }

    /// The lines git writes between `diff --git` and the hunks: renames, copies, modes, the `index` line and the
    /// binary markers.
    private mutating func applyExtendedHeader(_ line: Substring) {
        if line.hasPrefix("rename from ") || line.hasPrefix("copy from ") {
            current?.oldPath = UnifiedPatch.unquoted(UnifiedPatch.renamePath(line))
        } else if line.hasPrefix("rename to ") || line.hasPrefix("copy to ") {
            current?.newPath = UnifiedPatch.unquoted(UnifiedPatch.renamePath(line))
        } else if line.hasPrefix("old mode ") {
            current?.oldMode = String(line.dropFirst("old mode ".count))
        } else if line.hasPrefix("new mode ") {
            current?.newMode = String(line.dropFirst("new mode ".count))
        } else if line.hasPrefix("index ") {
            UnifiedPatch.applyIndex(line.dropFirst("index ".count), to: &current)
        } else if line.hasPrefix("new file mode") {
            current?.oldPath = nil
            current?.newMode = String(line.dropFirst("new file mode ".count))
        } else if line.hasPrefix("deleted file mode") {
            current?.newPath = nil
            current?.oldMode = String(line.dropFirst("deleted file mode ".count))
        } else if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
            current?.isBinary = true
        }
    }
}

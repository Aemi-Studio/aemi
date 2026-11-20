/// The header lines of a patch: paths as git writes them, hunk headers, `index` lines.
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
extension UnifiedPatch {
    /// Splits `a/x b/y` into both paths; paths with spaces are matched on the `a/` `b/` prefixes, and paths git
    /// quotes, `"a/x" "b/y"`, are unquoted.
    static func gitHeaderPaths(_ rest: String) -> (String?, String?) {
        if rest.hasPrefix("\"") || rest.hasSuffix("\""), let quoted = quotedHeaderPaths(rest) { return quoted }
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
    static func renamePath(_ line: Substring) -> String {
        String(line.drop(while: { $0 != " " }).dropFirst().drop(while: { $0 != " " }).dropFirst())
    }

    static func headerPath(_ rest: Substring, stripping prefix: String) -> String? {
        var path = rest.split(separator: "\t", maxSplits: 1).first.map(String.init) ?? ""
        path = unquoted(path)
        if path == "/dev/null" { return nil }
        if path.hasPrefix(prefix) { path.removeFirst(prefix.count) }
        return path
    }

    static func hunkHeader(_ line: Substring) -> Hunk {
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

    /// The two paths of a `diff --git` line when either is quoted: each token is one quoted string or one run
    /// without spaces, and the `a/` and `b/` prefixes are dropped.
    static func quotedHeaderPaths(_ rest: String) -> (String?, String?)? {
        var tokens: [String] = []
        var remaining = Substring(rest).drop(while: { $0 == " " })
        while !remaining.isEmpty, tokens.count < 2 {
            if remaining.first == "\"" {
                var index = remaining.index(after: remaining.startIndex)
                var escaped = false
                while index < remaining.endIndex {
                    let character = remaining[index]
                    if escaped {
                        escaped = false
                    } else if character == "\\" {
                        escaped = true
                    } else if character == "\"" {
                        break
                    }
                    index = remaining.index(after: index)
                }
                guard index < remaining.endIndex else { return nil }
                tokens.append(unquoted(String(remaining[...index])))
                remaining = remaining[remaining.index(after: index)...].drop(while: { $0 == " " })
            } else {
                let end = remaining.firstIndex(of: " ") ?? remaining.endIndex
                tokens.append(String(remaining[..<end]))
                remaining = remaining[end...].drop(while: { $0 == " " })
            }
        }
        guard tokens.count == 2 else { return nil }
        func stripped(_ path: String, _ prefix: String) -> String {
            path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
        }
        return (stripped(tokens[0], "a/"), stripped(tokens[1], "b/"))
    }

    /// A path as git writes it: a quoted one has its quotes removed and its C escapes decoded (`\303\251` for
    /// `é`, `\t`, `\"`, `\\`); any other is returned as it is.
    static func unquoted(_ path: String) -> String {
        guard path.count >= 2, path.hasPrefix("\""), path.hasSuffix("\"") else { return path }
        var bytes: [UInt8] = []
        let body = Array(path.utf8.dropFirst().dropLast())
        var index = 0
        while index < body.count {
            let byte = body[index]
            guard byte == UInt8(ascii: "\\"), index + 1 < body.count else {
                bytes.append(byte)
                index += 1
                continue
            }
            let next = body[index + 1]
            if (UInt8(ascii: "0") ... UInt8(ascii: "3")).contains(next), index + 3 < body.count,
                let value = UInt8(String(decoding: body[(index + 1) ... (index + 3)], as: UTF8.self), radix: 8)
            {
                bytes.append(value)
                index += 4
                continue
            }
            let escapes: [UInt8: UInt8] = [
                UInt8(ascii: "a"): 0x07, UInt8(ascii: "b"): 0x08, UInt8(ascii: "t"): 0x09, UInt8(ascii: "n"): 0x0A,
                UInt8(ascii: "v"): 0x0B, UInt8(ascii: "f"): 0x0C, UInt8(ascii: "r"): 0x0D
            ]
            bytes.append(escapes[next] ?? next)
            index += 2
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Reads `index <old>..<new> [<mode>]`, or a combined diff's `index <p1>,<p2>..<result>`, into `file`.
    static func applyIndex(_ rest: Substring, to file: inout FileChange?) {
        let fields = rest.split(separator: " ")
        guard let ids = fields.first else { return }
        let sides = ids.split(separator: ".", omittingEmptySubsequences: true)
        guard sides.count == 2 else { return }
        file?.oldObjectID = String(sides[0].split(separator: ",").first ?? sides[0])
        file?.newObjectID = String(sides[1])
        if fields.count > 1 {
            let mode = String(fields[1])
            if file?.oldMode == nil, file?.oldPath != nil { file?.oldMode = mode }
            if file?.newMode == nil, file?.newPath != nil { file?.newMode = mode }
        }
    }

    /// A combined diff's hunk header, `@@@ -a,b -c,d +e,f @@@`: one `-` range per parent, the first parent's as the
    /// old side, and the result's as the new side.
    static func combinedHunkHeader(_ line: Substring) -> (hunk: Hunk, parents: Int)? {
        let marker = line.prefix(while: { $0 == "@" })
        guard marker.count >= 3 else { return nil }
        let tokens = line.dropFirst(marker.count).split(separator: " ")
        let ranges = tokens.prefix(while: { $0 != marker })
        guard let first = ranges.first(where: { $0.hasPrefix("-") }), let result = ranges.last, result.hasPrefix("+")
        else { return nil }
        func range(_ token: Substring) -> (Int, Int) {
            let parts = token.dropFirst().split(separator: ",", maxSplits: 1)
            let start = min(max(Int(parts.first ?? "") ?? 0, 0), maximumLineNumber)
            let count = min(max(parts.count > 1 ? Int(parts[1]) ?? 1 : 1, 0), maximumLineNumber)
            return (start, count)
        }
        let old = range(first)
        let new = range(result)
        return (Hunk(oldStart: old.0, oldCount: old.1, newStart: new.0, newCount: new.1), marker.count - 1)
    }
}

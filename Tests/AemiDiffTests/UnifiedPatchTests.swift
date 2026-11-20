import Foundation
import Testing

@testable import AemiDiff

struct UnifiedPatchTests {
    static let gitPatch = """
        From 1234 Mon Sep 17 00:00:00 2001
        Subject: [PATCH] Example

        diff --git a/Sources/App.swift b/Sources/App.swift
        index 1111..2222 100644
        --- a/Sources/App.swift
        +++ b/Sources/App.swift
        @@ -3,4 +3,4 @@ import Foundation
         let a = 1
        -let b = 2
        +let b = 3
         let c = 4
        \\ No newline at end of file
        diff --git a/New.swift b/New.swift
        new file mode 100644
        --- /dev/null
        +++ b/New.swift
        @@ -0,0 +1,2 @@
        +line one
        +line two
        diff --git a/Old.swift b/Old.swift
        deleted file mode 100644
        --- a/Old.swift
        +++ /dev/null
        @@ -1 +0,0 @@
        -gone
        diff --git a/Was.swift b/Is.swift
        similarity index 90%
        rename from Was.swift
        rename to Is.swift
        --- a/Was.swift
        +++ b/Is.swift
        @@ -10,2 +10,2 @@
         keep
        -old
        +new
        diff --git a/Image.png b/Image.png
        Binary files a/Image.png and b/Image.png differ
        """

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `git patches parse into per-file hunks with added, deleted, renamed and binary files`() {
        let files: [UnifiedPatch.FileChange] = UnifiedPatch(parsing: Self.gitPatch).files
        Self.expectPaths(
            of: files,
            old: ["Sources/App.swift", nil, "Old.swift", "Was.swift", "Image.png"],
            new: ["Sources/App.swift", "New.swift", nil, "Is.swift", "Image.png"]
        )
        let binary: [Bool] = files.map { (file: UnifiedPatch.FileChange) -> Bool in file.isBinary }
        #expect(binary == [false, false, false, false, true])
        #expect(files[3].isRename)
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `a git patch's first hunk holds its bounds and lines`() {
        let hunk = UnifiedPatch(parsing: Self.gitPatch).files[0].hunks[0]
        let bounds: [Int] = [hunk.oldStart, hunk.oldCount, hunk.newStart, hunk.newCount]
        #expect(bounds == [3, 4, 3, 4])
        let kinds: [UnifiedPatch.Hunk.LineKind] = [.context, .removed, .added, .context]
        #expect(hunk.lines.map(\.kind) == kinds)
        #expect(hunk.lines.map(\.text) == ["let a = 1", "let b = 2", "let b = 3", "let c = 4"])
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `reconstructed texts place hunks at their line numbers and omit missing sides`() {
        let patch = UnifiedPatch(parsing: Self.gitPatch)

        // `\ No newline at end of file` after a context line: neither side ends with a line break.
        Self.expectTexts(
            of: patch.files[0],
            old: "\n\nlet a = 1\nlet b = 2\nlet c = 4",
            new: "\n\nlet a = 1\nlet b = 3\nlet c = 4"
        )
        Self.expectTexts(of: patch.files[1], old: nil, new: "line one\nline two\n")
        Self.expectTexts(of: patch.files[2], old: "gone\n", new: nil)
        let renamed: String = patch.files[3].reconstructedTexts.new ?? ""
        let renamedLines: Int = renamed.split(separator: "\n", omittingEmptySubsequences: false).count
        #expect(renamedLines == 12)
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `plain unified diffs without git headers parse too`() {
        let text = """
            --- before.txt\t2024-01-01 10:00:00
            +++ after.txt\t2024-01-02 10:00:00
            @@ -1,2 +1,2 @@
             same
            -a
            +b
            --- other.txt
            +++ other.txt
            @@ -1 +1 @@
            -x
            +y
            """
        let patch = UnifiedPatch(parsing: text)

        let oldPaths: [String?] = ["before.txt", "other.txt"]
        let newPaths: [String?] = ["after.txt", "other.txt"]
        let texts: [String] = ["same", "a", "b"]
        let kinds: [UnifiedPatch.Hunk.LineKind] = [.removed, .added]
        let files: [UnifiedPatch.FileChange] = patch.files
        let actualOld: [String?] = files.map { (file: UnifiedPatch.FileChange) -> String? in file.oldPath }
        let actualNew: [String?] = files.map { (file: UnifiedPatch.FileChange) -> String? in file.newPath }
        let actualTexts: [String] = files[0].hunks[0].lines
            .map { (line: UnifiedPatch.Hunk.Line) -> String in line.text }
        let actualKinds: [UnifiedPatch.Hunk.LineKind] = files[1].hunks[0].lines
            .map {
                (line: UnifiedPatch.Hunk.Line) -> UnifiedPatch.Hunk.LineKind in line.kind
            }
        #expect(actualOld == oldPaths)
        #expect(actualNew == newPaths)
        #expect(actualTexts == texts)
        #expect(actualKinds == kinds)
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `blank lines inside a hunk are context and CRLF endings are stripped`() {
        let patch = UnifiedPatch(
            parsing: "--- a/x.txt\r\n+++ b/x.txt\r\n@@ -1,3 +1,3 @@\r\n one\r\n\r\n-two\r\n+deux\r\n"
        )

        #expect(
            patch.files[0].hunks[0].lines == [
                .init(kind: .context, text: "one"), .init(kind: .context, text: ""),
                .init(kind: .removed, text: "two"), .init(kind: .added, text: "deux")
            ]
        )
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `a hunk header naming an absurd line number is clamped instead of padding a document with it`() {
        let patch = UnifiedPatch(
            parsing: """
                --- a/f
                +++ b/f
                @@ -9223372036854775807,1 +99999999999,1 @@
                -x
                +y
                """
        )
        let file = patch.files[0]
        #expect(file.hunks[0].oldStart == UnifiedPatch.maximumLineNumber)
        #expect(file.hunks[0].newStart == UnifiedPatch.maximumLineNumber)
        let texts = file.reconstructedTexts
        #expect((texts.new ?? "").utf8.count <= UnifiedPatch.maximumLineNumber + 2)
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `a side that gains or loses its final line break is told apart from the other`() {
        let patch = UnifiedPatch(
            parsing: """
                diff --git a/a.txt b/a.txt
                --- a/a.txt
                +++ b/a.txt
                @@ -1 +1 @@
                -a
                \\ No newline at end of file
                +a
                diff --git a/b.txt b/b.txt
                --- a/b.txt
                +++ b/b.txt
                @@ -1 +1 @@
                -b
                +b
                \\ No newline at end of file

                """
        )

        Self.expectTexts(of: patch.files[0], old: "a", new: "a\n")
        Self.expectTexts(of: patch.files[1], old: "b\n", new: "b")
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `paths git quotes with C escapes are decoded`() {
        let patch = UnifiedPatch(
            parsing: """
                diff --git "a/caf\\303\\251.txt" "b/caf\\303\\251.txt"
                index 1111111..2222222 100644
                Binary files "a/caf\\303\\251.txt" and "b/caf\\303\\251.txt" differ
                diff --git "a/tab\\there.txt" b/plain.txt
                similarity index 100%
                rename from "tab\\there.txt"
                rename to plain.txt
                diff --git "a/x\\"y.txt" "b/x\\"y.txt"
                --- "a/x\\"y.txt"
                +++ "b/x\\"y.txt"
                @@ -1 +1 @@
                -1
                +2

                """
        )

        Self.expectPaths(
            of: patch.files,
            old: ["café.txt", "tab\there.txt", "x\"y.txt"],
            new: ["café.txt", "plain.txt", "x\"y.txt"]
        )
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `modes and object ids come from the extended headers`() {
        let patch = UnifiedPatch(
            parsing: """
                diff --git a/run.sh b/run.sh
                old mode 100644
                new mode 100755
                diff --git a/a.txt b/a.txt
                index 1111111..2222222 100644
                --- a/a.txt
                +++ b/a.txt
                @@ -1 +1 @@
                -1
                +2
                diff --git a/new.sh b/new.sh
                new file mode 100755
                index 0000000..3333333
                --- /dev/null
                +++ b/new.sh
                @@ -0,0 +1 @@
                +x

                """
        )
        let files: [UnifiedPatch.FileChange] = patch.files
        let oldModes: [String?] = files.map { (file: UnifiedPatch.FileChange) -> String? in file.oldMode }
        let newModes: [String?] = files.map { (file: UnifiedPatch.FileChange) -> String? in file.newMode }
        let oldIDs: [String?] = files.map { (file: UnifiedPatch.FileChange) -> String? in file.oldObjectID }
        let newIDs: [String?] = files.map { (file: UnifiedPatch.FileChange) -> String? in file.newObjectID }
        let expectedOldModes: [String?] = ["100644", "100644", nil]
        let expectedNewModes: [String?] = ["100755", "100644", "100755"]
        let expectedOldIDs: [String?] = [nil, "1111111", "0000000"]
        let expectedNewIDs: [String?] = [nil, "2222222", "3333333"]

        #expect(oldModes == expectedOldModes)
        #expect(newModes == expectedNewModes)
        #expect(oldIDs == expectedOldIDs)
        #expect(newIDs == expectedNewIDs)
        #expect(files[0].hunks.isEmpty)
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `a merge's combined diff reads against its first parent`() {
        let patch = UnifiedPatch(
            parsing: """
                diff --cc a.txt
                index 1111111,2222222..3333333
                --- a/a.txt
                +++ b/a.txt
                @@@ -1,2 -1,3 +1,3 @@@
                  same
                - ours
                 -theirs
                ++merged
                + from theirs
                diff --git a/next.txt b/next.txt
                --- a/next.txt
                +++ b/next.txt
                @@ -1 +1 @@
                -n
                +m

                """
        )
        let file = patch.files[0]

        #expect(patch.files.count == 2)
        #expect(file.isCombined)
        #expect(file.oldPath == "a.txt" && file.newPath == "a.txt")
        Self.expectTexts(of: file, old: "same\nours\n", new: "same\nmerged\nfrom theirs\n")
        Self.expectTexts(of: patch.files[1], old: "n\n", new: "m\n")
    }

    /// Each file's old and new paths.
    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    private static func expectPaths(of files: [UnifiedPatch.FileChange], old: [String?], new: [String?]) {
        let actualOld: [String?] = files.map { (file: UnifiedPatch.FileChange) -> String? in file.oldPath }
        let actualNew: [String?] = files.map { (file: UnifiedPatch.FileChange) -> String? in file.newPath }
        #expect(actualOld == old)
        #expect(actualNew == new)
    }

    /// The texts a file's hunks rebuild, each side compared on its own.
    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    private static func expectTexts(of file: UnifiedPatch.FileChange, old: String?, new: String?) {
        let texts: (old: String?, new: String?) = file.reconstructedTexts
        #expect(texts.old == old)
        #expect(texts.new == new)
    }
}

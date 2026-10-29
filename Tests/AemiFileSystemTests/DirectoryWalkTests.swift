import AemiIO
import Foundation
import Testing

@testable import AemiFileSystem

/// An entry, spelled briefly: `file("A/B.swift")`.
private func file(_ path: String) -> DirectoryWalk.Entry { DirectoryWalk.Entry(relativePath: path, kind: .file) }
private func link(_ path: String) -> DirectoryWalk.Entry { DirectoryWalk.Entry(relativePath: path, kind: .link) }
private func directory(_ path: String) -> DirectoryWalk.Entry {
    DirectoryWalk.Entry(relativePath: path, kind: .directory)
}

@Suite(.serialized) struct DirectoryWalkTests {
    private static let skipped: Set<String> = [".build", ".git", "DerivedData"]

    /// A fresh directory, resolved through links, holding `files` (relative path: contents) and empty `directories`.
    private static func tree(files: [String: String], directories: [String] = []) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "walk-\(UUID().uuidString)")
        for path in directories {
            try FileManager.default.createDirectory(at: root.appending(path: path), withIntermediateDirectories: true)
        }
        for (path, text) in files {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        return URL(fileURLWithPath: root.path).resolvingSymlinksInPath()
    }

    private static let sample: [String: String] = [
        "Package.swift": "", "README.md": "", ".hidden.swift": "", "Sources/App/App.swift": "",
        "Sources/App/Model.swift": "", "Sources/App/.secret": "", "Sources/Lib/Deep/Nested/Leaf.swift": "",
        "Sources/Lib/Deep/Notes.txt": "", ".build/debug/Junk.swift": "", "Tests/AppTests/AppTests.swift": "",
        "DerivedData/X.swift": "", "Generated/API.swift": "", "Generated/More/B.swift": ""
    ]

    /// What `FileManager` reports for the same policy: the reference the walker must equal.
    private static func reference(_ root: URL, includesHidden: Bool = false) throws -> [DirectoryWalk.Entry] {
        var entries: [DirectoryWalk.Entry] = []
        var stack = [""]
        while let relative = stack.popLast() {
            let directory = relative.isEmpty ? root : root.appending(path: relative)
            for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
                guard !skipped.contains(name), includesHidden || !name.hasPrefix(".") else { continue }
                let path = relative.isEmpty ? name : relative + "/" + name
                let type =
                    try FileManager.default.attributesOfItem(atPath: directory.appending(path: name).path)[.type]
                    as? FileAttributeType
                switch type {
                    case .typeDirectory: stack.append(path)
                    case .typeRegular: entries.append(.init(relativePath: path, kind: .file))
                    case .typeSymbolicLink: entries.append(.init(relativePath: path, kind: .link))
                    default: entries.append(.init(relativePath: path, kind: .other))
                }
            }
        }
        return entries.sorted { $0.relativePath < $1.relativePath }
    }

    @Test func `the walk equals FileManager's listing under the same policy, in one worker or many`() throws {
        let root = try Self.tree(files: Self.sample, directories: ["Empty/Inner"])
        defer { try? FileManager.default.removeItem(at: root) }
        let expected = try Self.reference(root)
        for workers in [1, 2, 4, 8] {
            let result = try DirectoryWalk.walk(root.path, policy: .init(skippedNames: Self.skipped, workers: workers))
            #expect(result.entries == expected, "\(workers) worker(s)")
            #expect(result.failures.isEmpty && !result.limited && !result.cancelled)
            #expect(result.root == root.path)
        }
        let hidden = try DirectoryWalk.walk(root.path, policy: .init(skippedNames: Self.skipped, includesHidden: true))
        #expect(hidden.entries == (try Self.reference(root, includesHidden: true)))
    }

    @Test func `no regular file is stat'ed, and only the directories walked are opened`() throws {
        let root = try Self.tree(files: Self.sample)
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try DirectoryWalk.walk(root.path, policy: .init(skippedNames: Self.skipped))
        #expect(result.entries.count == 9)
        #expect(result.statistics.statCalls == 0)
        // the root, Sources, App, Lib, Deep, Nested, Tests, AppTests, Generated, More
        #expect(result.statistics.directoriesOpened == 10)
        #expect(result.statistics.peakOpenDescriptors <= 4 + 1)
    }

    @Test func `the predicate prunes a directory before it is entered, and refuses single entries`() throws {
        let root = try Self.tree(files: Self.sample)
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = DirectoryWalk.Policy(
            skippedNames: Self.skipped,
            accepts: { $0.relativePath != "Generated" && !$0.name.hasSuffix(".md") })
        let result = try DirectoryWalk.walk(root.path, policy: policy)
        let pruned: Bool = result.entries.contains { $0.relativePath.hasPrefix("Generated") }
        let refused: Bool = result.entries.contains { $0.relativePath.hasSuffix(".md") }
        #expect(!pruned && !refused)
        #expect(result.entries.count == 6)
        #expect(result.statistics.directoriesOpened == 8)
    }

    @Test func `directories are reported when asked`() throws {
        let root = try Self.tree(files: ["A/B/C.swift": ""])
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try DirectoryWalk.walk(root.path, policy: .init(reportsDirectories: true))
        #expect(
            result.entries == [
                .init(relativePath: "A", kind: .directory), .init(relativePath: "A/B", kind: .directory),
                .init(relativePath: "A/B/C.swift", kind: .file)
            ])
    }

    /// A root with a link to a directory inside it, a cycle, a link out of it, a dangling link and a link to a file.
    private static func linkedTree() throws -> (root: URL, outside: URL) {
        let root = try tree(files: ["Real/A.swift": "", "Real/Sub/B.swift": ""])
        let outside = try tree(files: ["Outside.swift": ""])
        let links: [(String, String)] = [
            ("Alias", "Real"), ("Real/Sub/Up", "../.."), ("Away", outside.path), ("Dangling.swift", "Nowhere"),
            ("File.swift", "Real/A.swift")
        ]
        for (name, destination) in links {
            try FileManager.default.createSymbolicLink(
                atPath: root.appending(path: name).path, withDestinationPath: destination)
        }
        return (root, outside)
    }

    @Test func `links are reported and not followed by default`() throws {
        let (root, outside) = try Self.linkedTree()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let result = try DirectoryWalk.walk(root.path, policy: .init(links: .never))
        let expected: [DirectoryWalk.Entry] = [
            link("Alias"), link("Away"), link("Dangling.swift"), link("File.swift"), file("Real/A.swift"),
            file("Real/Sub/B.swift"), link("Real/Sub/Up")
        ]
        #expect(result.entries == expected)
    }

    /// Inside the root, a link stands for its target, which the walk reaches at its own path: Alias, Up (a cycle) and
    /// File.swift are not reported, and no link is ever descended, so no cycle can loop. A link out of the root and a
    /// dangling one stay links, and nothing outside the root is listed.
    @Test func `links into the root are left to their targets, and none out of it is followed`() throws {
        let (root, outside) = try Self.linkedTree()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        for workers in [1, 4] {
            let result = try DirectoryWalk.walk(root.path, policy: .init(links: .withinRoot, workers: workers))
            let expected: [DirectoryWalk.Entry] = [
                link("Away"), link("Dangling.swift"), file("Real/A.swift"), file("Real/Sub/B.swift")
            ]
            #expect(result.entries == expected, "\(workers) worker(s)")
        }
    }

    @Test func `a directory replaced by a link while the walk runs is refused, not followed`() throws {
        let root = try Self.tree(files: ["Victim/Inside.swift": "", "Victim/Deeper/More.swift": ""])
        let target = try Self.tree(files: ["Secret.swift": "", "Deeper/Hidden.swift": ""])
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: target)
        }
        let victim = root.appending(path: "Victim").path
        let result = try DirectoryWalk.walk(
            root.path, policy: .init(workers: 1),
            afterListing: { listed in
                // Once Victim has been listed, swap it for a link to another tree before Deeper is opened.
                guard listed == "Victim" else { return }
                try? FileManager.default.removeItem(atPath: victim)
                try? FileManager.default.createSymbolicLink(atPath: victim, withDestinationPath: target.path)
            })
        let leaked: Bool = result.entries.contains {
            $0.relativePath.contains("Hidden") || $0.relativePath.contains("Secret")
        }
        #expect(!leaked)
        #expect(result.failures.map(\.relativePath) == ["Victim/Deeper"])
    }

    @Test func `an unreadable directory is reported with its error and the rest is walked`() throws {
        let root = try Self.tree(files: ["Open/A.swift": "", "Closed/B.swift": ""])
        let closed = root.appending(path: "Closed").path
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: closed)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: closed)
            try? FileManager.default.removeItem(at: root)
        }
        let result = try DirectoryWalk.walk(root.path)
        let expected: [DirectoryWalk.Entry] = [file("Open/A.swift")]
        #expect(result.entries == expected)
        #expect(result.failures.map(\.relativePath) == ["Closed"])
        #expect(result.failures.first?.error.errno == EACCES)
        #expect(throws: IOError.self) { try DirectoryWalk.walk(root.appending(path: "Absent").path) }
    }

    @Test func `a limit stops the walk and says so; cancellation stops it and says so`() throws {
        let root = try Self.tree(
            files: Dictionary(uniqueKeysWithValues: (0 ..< 50).map { ("D\($0 % 5)/F\($0).swift", "") }))
        defer { try? FileManager.default.removeItem(at: root) }
        let limited = try DirectoryWalk.walk(root.path, policy: .init(limit: 7))
        #expect(limited.entries.count == 7 && limited.limited)
        let cancelled = try DirectoryWalk.walk(root.path, policy: .init(isCancelled: { true }))
        #expect(cancelled.cancelled && cancelled.entries.isEmpty)
    }

    @Test func `batches deliver the walk's entries while it runs`() async throws {
        let root = try Self.tree(files: Self.sample)
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = DirectoryWalk.Policy(skippedNames: Self.skipped)
        var streamed: [DirectoryWalk.Entry] = []
        var batches = 0
        for try await batch in DirectoryWalk.batches(root.path, policy: policy) {
            #expect(batch == batch.sorted { $0.relativePath < $1.relativePath })
            streamed += batch
            batches += 1
        }
        #expect(batches > 1)
        #expect(
            streamed.sorted { $0.relativePath < $1.relativePath }
                == (try DirectoryWalk.walk(root.path, policy: policy).entries))
        var failed = false
        do { for try await _ in DirectoryWalk.batches(root.appending(path: "Absent").path) {} } catch {
            failed = error is IOError
        }
        #expect(failed)
    }
}

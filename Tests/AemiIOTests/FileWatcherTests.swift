import Foundation
import Testing

@testable import AemiIO

#if os(macOS)
    extension EventReader {
        /// FSEvents names the entry that changed: a marker's own canonical path closes the settling.
        mutating func settle(writing marker: String) async throws -> FileWatchEvent? {
            try await settle(writing: marker, marking: .directoryChanged(CanonicalPath.of(marker)))
        }
    }

    @Suite(.tags(.fileWatcher), .timeLimit(.minutes(1)))
    struct FileWatcherTests {
        @Test func `watching a directory surfaces an event when a file inside it changes`() async throws {
            let tree = try TempTree()
            try tree.createFile(named: "existing.txt", content: "before")
            let watcher = FileWatcher()
            var reader = EventReader(watcher)
            await watcher.watchDirectory(tree.root)

            try "after".write(toFile: tree.root + "/new.txt", atomically: true, encoding: .utf8)

            #expect(await reader.next(.directoryChanged(CanonicalPath.of(tree.root + "/new.txt"))) != nil)
            await watcher.stop()
        }

        /// A released watcher or a stopped stream must never leave FSEvents calling into freed state: the app crashed
        /// in the field with a callback yielding through a deallocated context box.
        @Test func `stopping or dropping watchers while their events are in flight never reaches freed state`()
            async throws
        {
            let tree = try TempTree()
            try tree.createFile(named: "churn.txt", content: "0")
            for round in 0 ..< 60 {
                let watcher = FileWatcher()
                await watcher.watchDirectory(tree.root)
                try "\(round)".write(toFile: tree.root + "/churn.txt", atomically: true, encoding: .utf8)
                // Even rounds stop explicitly; odd rounds drop the watcher and leave teardown to its deinit.
                if round.isMultiple(of: 2) { await watcher.stop() }
            }
            let survivor = FileWatcher()
            var reader = EventReader(survivor)
            await survivor.watchDirectory(tree.root)
            try "done".write(toFile: tree.root + "/churn.txt", atomically: true, encoding: .utf8)
            #expect(await reader.next(.directoryChanged(CanonicalPath.of(tree.root + "/churn.txt"))) != nil)
            await survivor.stop()
        }

        @Test func `a write under the second of two watched directories raises an event`() async throws {
            let first = try TempTree()
            let second = try TempTree()
            let watcher = FileWatcher()
            var reader = EventReader(watcher)
            await watcher.watchDirectory(first.root)
            await watcher.watchDirectory(second.root)

            try second.createFile(named: "added.txt", content: "x")

            #expect(await reader.next(.directoryChanged(CanonicalPath.of(second.root + "/added.txt"))) != nil)
            await watcher.stop()
        }

        @Test func `a watched file keeps reporting after three atomic saves`() async throws {
            let tree = try TempTree()
            try tree.createFile(named: "saved.txt", content: "0")
            let path = tree.root + "/saved.txt"
            let watcher = FileWatcher()
            var reader = EventReader(watcher)
            await watcher.watchFile(path)

            for save in 1 ... 3 {
                // An atomic save writes a temporary file, then renames it over the watched path: the inode changes.
                try "\(save)".write(toFile: path, atomically: true, encoding: .utf8)
                #expect(await reader.next(.fileChanged(path)) != nil, "save \(save)")
                // Reads this save's remaining events, so the next save's event cannot be an echo of this one.
                #expect(try await reader.settle(writing: tree.root + "/marker-\(save)") != nil)
            }
            await watcher.stop()
        }

        @Test func `a suppressed path raises neither kind of event while an unsuppressed one does`() async throws {
            let tree = try TempTree()
            try tree.createFile(named: "watched.txt", content: "0")
            let watched = tree.root + "/watched.txt"
            let plain = tree.root + "/plain.txt"
            // A window far longer than the test keeps the outcome independent of how fast FSEvents delivers.
            let watcher = FileWatcher(latency: 0.1, suppressionWindow: .seconds(3_600))
            var reader = EventReader(watcher)
            await watcher.watchDirectory(tree.root)
            await watcher.watchFile(watched)
            watcher.suppressNotifications(for: watched)
            watcher.suppressNotifications(for: plain)

            try Data("1".utf8).write(to: URL(fileURLWithPath: watched))
            try Data("1".utf8).write(to: URL(fileURLWithPath: plain))

            #expect(try await reader.settle(writing: tree.root + "/unsuppressed.txt") != nil)
            #expect(!reader.seen.contains(.fileChanged(watched)))
            #expect(!reader.seen.contains(.directoryChanged(CanonicalPath.of(watched))))
            #expect(!reader.seen.contains(.directoryChanged(CanonicalPath.of(plain))))
            await watcher.stop()
        }

        @Test func `a file watched through the tmp symlink reports under the path the caller registered`() async throws
        {
            let directory = "/tmp/aemiio-file-watcher-\(UUID().uuidString)"
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(atPath: directory) }
            let path = directory + "/watched.txt"
            try "0".write(toFile: path, atomically: true, encoding: .utf8)
            let watcher = FileWatcher()
            var reader = EventReader(watcher)
            await watcher.watchFile(path)

            try "1".write(toFile: path, atomically: true, encoding: .utf8)

            let event = await reader.next { event in
                if case .fileChanged = event { true } else { false }
            }
            #expect(event == .fileChanged(path))
            await watcher.stop()
        }

        @Test func `events written between two stream generations arrive once the new stream starts`() async throws {
            let first = try TempTree()
            let second = try TempTree()
            let written = FileWatchEvent.directoryChanged(CanonicalPath.of(first.root + "/between.txt"))
            let observer = FileWatcher()
            var observed = EventReader(observer)
            await observer.watchDirectory(first.root)
            // A latency far past the test's own steps holds the write inside the first stream when the second replaces it.
            let watcher = FileWatcher(latency: 30, suppressionWindow: .seconds(1))
            var reader = EventReader(watcher)
            await watcher.watchDirectory(first.root)
            await watcher.synchronizeStream()

            try first.createFile(named: "between.txt", content: "x")
            // FSEvents numbers events asynchronously; once another stream has the write, its ID precedes the restart.
            #expect(await observed.next(written) != nil)
            await watcher.watchDirectory(second.root)

            #expect(await reader.next(written) != nil)
            await watcher.stop()
            await observer.stop()
        }

        @Test func `an excluded directory raises nothing`() async throws {
            let tree = try TempTree()
            try tree.createDirectory(named: "excluded")
            let excluded = tree.root + "/excluded"
            let watcher = FileWatcher()
            var reader = EventReader(watcher)
            await watcher.watchDirectory(tree.root)
            try await watcher.excludeDirectories([excluded])
            await watcher.synchronizeStream()

            try tree.createFile(named: "excluded/inside.txt", content: "x")

            #expect(try await reader.settle(writing: tree.root + "/outside.txt") != nil)
            // FSEvents filters what lies below an excluded directory; the directory's own entry, created just before the
            // watch began, may still be reported.
            let canonicalExcluded = CanonicalPath.of(excluded)
            #expect(
                !reader.seen.contains { event in
                    guard case .directoryChanged(let path) = event else { return false }
                    return path != canonicalExcluded && CanonicalPath.isInside(path, canonicalExcluded)
                })
            await watcher.stop()
        }

        @Test func `excluding more than eight directories is refused`() async {
            let watcher = FileWatcher()
            let nine = (0 ..< 9).map { "/tmp/excluded-\($0)" }
            await #expect(throws: FileWatcher.ExclusionError.tooManyDirectories(9)) {
                try await watcher.excludeDirectories(nine)
            }
            await watcher.stop()
        }

        @Test func `an unwatched file reports its later changes as directory changes`() async throws {
            let tree = try TempTree()
            try tree.createFile(named: "closed.txt", content: "0")
            let path = tree.root + "/closed.txt"
            let watcher = FileWatcher()
            var reader = EventReader(watcher)
            await watcher.watchDirectory(tree.root)
            await watcher.watchFile(path)
            await watcher.unwatchFile(path)

            try Data("1".utf8).write(to: URL(fileURLWithPath: path))

            #expect(await reader.next(.directoryChanged(CanonicalPath.of(path))) != nil)
            #expect(!reader.seen.contains(.fileChanged(path)))
            await watcher.stop()
        }

        @Test func `a consumer that falls behind the event buffer is told to rescan everything it watches`()
            async throws
        {
            let tree = try TempTree()
            try tree.createFile(named: "watched.txt", content: "0")
            let watched = tree.root + "/watched.txt"
            let watcher = FileWatcher()
            var reader = EventReader(watcher)
            await watcher.watchDirectory(tree.root)
            await watcher.watchFile(watched)

            // Nothing reads while these land, so the buffer drops the oldest; only a rescan reports the untouched file.
            for index in 0 ..< FileWatcher.eventBufferLimit + 100 {
                FileManager.default.createFile(atPath: tree.root + "/burst-\(index)", contents: nil)
            }

            #expect(await reader.next(.fileChanged(watched)) != nil)
            #expect(await reader.next(.directoryChanged(CanonicalPath.of(tree.root))) != nil)
            await watcher.stop()
        }

        @Test func `the event stream finishes after stop`() async {
            let watcher = FileWatcher()
            await watcher.stop()

            var iterator = watcher.events.makeAsyncIterator()
            let next = await iterator.next()

            #expect(next == nil)
        }
    }

    @Suite(.tags(.fileWatcher))
    struct WatchTableTests {
        private static func noSuppression(_: String) -> Bool { false }

        /// A table watching `directories` and `files` (registered path, then canonical keys), each since event 100.
        private static func table(directories: [String] = [], files: [(String, [String])] = []) -> WatchTable {
            var table = WatchTable()
            for directory in directories {
                _ = table.insertDirectory(directory, since: 100)
            }
            for (registered, keys) in files {
                table.insertFile(registered, keys: keys, since: 100)
            }
            return table
        }

        @Test func `the stream covers each directory once, nested ones and watched files inside their parents`() {
            let table = Self.table(
                directories: ["/a", "/a/b", "/a-b"], files: [("/x/f", ["/a/b/f"]), ("/d/e/g", ["/d/e/g"])])
            #expect(table.roots == ["/a", "/a-b", "/d/e"])
        }

        @Test func `an event on a watched key reports every path registered for it`() {
            let table = Self.table(directories: ["/w"], files: [("/link/f", ["/w/f"]), ("/w/f", ["/w/f"])])
            let route = table.route(path: "/w/f", flags: 0, id: 101, isSuppressed: Self.noSuppression)
            #expect(route == .files(["/link/f", "/w/f"]))
        }

        @Test func `any other event reports its canonical path as a directory change`() {
            let table = Self.table(directories: ["/w"], files: [("/w/f", ["/w/f"])])
            #expect(
                table.route(path: "/w/g", flags: 0, id: 101, isSuppressed: Self.noSuppression) == .directory("/w/g"))
        }

        @Test func `a suppressed path reports nothing, as a file or as a directory`() {
            let table = Self.table(directories: ["/w"], files: [("/w/f", ["/w/f"])])
            for path in ["/w/f", "/w/g"] {
                #expect(table.route(path: path, flags: 0, id: 101, isSuppressed: { _ in true }) == .skip)
            }
        }

        @Test func `an event older than every watch covering its path is skipped`() {
            var table = WatchTable()
            _ = table.insertDirectory("/old", since: 50)
            _ = table.insertDirectory("/new", since: 100)
            table.insertFile("/new/f", keys: ["/elsewhere/f"], since: 100)
            #expect(table.isStale("/old/x", id: 40))
            #expect(!table.isStale("/old/x", id: 60))
            #expect(table.isStale("/new/x", id: 60))
            #expect(table.isStale("/elsewhere/sibling", id: 100))
            #expect(!table.isStale("/elsewhere/sibling", id: 101))
            #expect(table.isStale("/unwatched/x", id: 60))
        }

        @Test func `the end of replayed history reports nothing`() {
            let table = Self.table(directories: ["/w"])
            let flags = FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone)
            #expect(table.route(path: "/w", flags: flags, id: 101, isSuppressed: Self.noSuppression) == .skip)
        }

        @Test func `a must-scan event rescans everything watched below its path`() {
            let table = Self.table(directories: ["/w"], files: [("/w/sub/f", ["/w/sub/f"]), ("/w/g", ["/w/g"])])
            let flags = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
            #expect(
                table.route(path: "/w/sub", flags: flags, id: 1, isSuppressed: Self.noSuppression) == .rescan("/w/sub"))
            #expect(table.rescanEvents(below: "/w/sub") == [.fileChanged("/w/sub/f"), .directoryChanged("/w/sub")])
        }

        @Test func `rescanning from the root reports every watched file and directory`() {
            let table = Self.table(directories: ["/a", "/b"], files: [("/link/f", ["/c/f"])])
            #expect(
                table.rescanEvents(below: "/") == [
                    .fileChanged("/link/f"), .directoryChanged("/a"), .directoryChanged("/b")
                ])
        }

        @Test func `unwatching one of two paths registered for a key keeps reporting the other`() {
            var table = Self.table(files: [("/link/f", ["/w/f"]), ("/w/f", ["/w/f"])])
            table.removeFile("/link/f", keys: ["/w/f"])
            #expect(table.route(path: "/w/f", flags: 0, id: 101, isSuppressed: Self.noSuppression) == .files(["/w/f"]))
            table.removeFile("/w/f", keys: ["/w/f"])
            #expect(table.roots.isEmpty)
        }
    }

    @Suite(.tags(.fileWatcher))
    struct CanonicalPathTests {
        @Test func `a path below a missing directory still resolves the tmp symlink`() {
            let missing = "/tmp/aemiio-missing-\(UUID().uuidString)/child.txt"
            #expect(CanonicalPath.of(missing) == "/private" + missing)
        }

        @Test func `a symlinked file answers to both its target and its own location`() throws {
            let tree = try TempTree()
            try tree.createFile(named: "target.txt", content: "x")
            let link = tree.root + "/link.txt"
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: tree.root + "/target.txt")
            let root = CanonicalPath.of(tree.root)
            #expect(CanonicalPath.keys(forFile: link) == [root + "/target.txt", root + "/link.txt"])
        }

        @Test(arguments: [
            ("/a/b", "/a", true), ("/a", "/a", true), ("/a-b", "/a", false), ("/ab", "/a", false), ("/a", "/", true),
            ("/a", "/a/b", false)
        ])
        func `a path lies inside a directory only along whole components`(path: String, directory: String, inside: Bool)
        {
            #expect(CanonicalPath.isInside(path, directory) == inside)
        }
    }

    @Suite(.tags(.fileWatcher))
    struct SuppressionWindowTests {
        @Test func `a path recorded inside the window reports suppressed`() {
            let window = SuppressionWindow(window: .seconds(1))
            window.record("/a", now: .seconds(10))

            #expect(window.isSuppressed("/a", now: .seconds(10.5)))
        }

        @Test func `a path is no longer suppressed once the window elapses`() {
            let window = SuppressionWindow(window: .seconds(1))
            window.record("/a", now: .seconds(10))

            #expect(!window.isSuppressed("/a", now: .seconds(11.5)))
        }

        @Test func `an unrecorded path is never suppressed`() {
            let window = SuppressionWindow(window: .seconds(1))

            #expect(!window.isSuppressed("/never-recorded", now: .seconds(10)))
        }
    }
#endif

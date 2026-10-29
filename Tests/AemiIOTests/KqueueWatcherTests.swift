import Foundation
import Testing

@testable import AemiIO

#if canImport(Darwin)
    /// Against real files and a real kqueue. No sleeps: every wait ends on an event, and the time limit fails a test whose
    /// event never comes.
    @Suite(.tags(.fileWatcher), .timeLimit(.minutes(1)))
    struct KqueueWatcherTests {
        /// Writes in place: same inode, the directory untouched.
        private func overwrite(_ path: String, _ text: String) throws {
            let handle = try #require(FileHandle(forWritingAtPath: path))
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: Data(text.utf8))
            try handle.close()
        }

        @Test func `a write in place to a watched file is reported`() async throws {
            let tree = try TempTree()
            try tree.createFile(named: "config.json", content: "{}")
            let path = tree.root + "/config.json"
            let watcher = try KqueueWatcher()
            var reader = EventReader(watcher)
            watcher.watchFile(path)

            try overwrite(path, "{\"a\": 1}")

            #expect(await reader.next(.fileChanged(path)) != nil)
            watcher.stop()
        }

        @Test func `a watched file keeps reporting after three atomic saves`() async throws {
            let tree = try TempTree()
            try tree.createFile(named: "saved.txt", content: "0")
            try tree.createFile(named: "marker", content: "0")
            let path = tree.root + "/saved.txt"
            let marker = tree.root + "/marker"
            let watcher = try KqueueWatcher()
            var reader = EventReader(watcher)
            watcher.watchFile(path)
            watcher.watchFile(marker)

            for save in 1 ... 3 {
                try tree.createFile(named: "saved.txt", content: "\(save)")
                #expect(await reader.next(.fileChanged(path)) != nil, "save \(save)")
                // Reads this save's remaining events, so the next save's report cannot be an echo of this one.
                try overwrite(marker, "\(save)")
                #expect(await reader.next(.fileChanged(marker)) != nil)
            }
            watcher.stop()
        }

        @Test func `a file whose directories do not exist yet is reported once it is written`() async throws {
            let tree = try TempTree()
            let path = tree.root + "/project/.ask/config.json"
            let watcher = try KqueueWatcher()
            var reader = EventReader(watcher)
            watcher.watchFile(path)

            try tree.createDirectory(named: "project")
            try tree.createDirectory(named: "project/.ask")
            try tree.createFile(named: "project/.ask/config.json", content: "{}")

            #expect(await reader.next(.fileChanged(path)) != nil)
            watcher.stop()
        }

        @Test func `a file is followed when its directory is removed and made again`() async throws {
            let tree = try TempTree()
            try tree.createDirectory(named: "settings")
            try tree.createFile(named: "settings/a.json", content: "1")
            let path = tree.root + "/settings/a.json"
            let watcher = try KqueueWatcher()
            var reader = EventReader(watcher)
            watcher.watchFile(path)

            try FileManager.default.removeItem(atPath: tree.root + "/settings")
            #expect(await reader.next(.fileChanged(path)) != nil, "the removal")
            try tree.createDirectory(named: "settings")
            try tree.createFile(named: "settings/a.json", content: "2")

            #expect(await reader.next { _ in FileIdentity(path: path) != nil } != nil, "the file made again")
            watcher.stop()
        }

        @Test func `removing a watched file is reported`() async throws {
            let tree = try TempTree()
            try tree.createFile(named: "gone.txt", content: "x")
            let path = tree.root + "/gone.txt"
            let watcher = try KqueueWatcher()
            var reader = EventReader(watcher)
            watcher.watchFile(path)

            try FileManager.default.removeItem(atPath: path)

            #expect(await reader.next(.fileChanged(path)) != nil)
            watcher.stop()
        }

        @Test func `a watched directory reports entries added to it, not those below it`() async throws {
            let tree = try TempTree()
            try tree.createDirectory(named: "nested")
            let watcher = try KqueueWatcher()
            var reader = EventReader(watcher)
            watcher.watchDirectory(tree.root)
            let directory = FileWatchEvent.directoryChanged(CanonicalPath.of(tree.root))

            try tree.createFile(named: "nested/deep.txt", content: "x")
            try tree.createFile(named: "added.txt", content: "x")

            #expect(await reader.next(directory) != nil)
            #expect(reader.seen == [directory], "one event, for the entry added at the top")
            watcher.stop()
        }

        @Test func `a file watched through the tmp symlink reports under the path the caller registered`() async throws
        {
            let directory = "/tmp/aemiio-kqueue-\(UUID().uuidString)"
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(atPath: directory) }
            let path = directory + "/watched.txt"
            try "0".write(toFile: path, atomically: true, encoding: .utf8)
            let watcher = try KqueueWatcher()
            var reader = EventReader(watcher)
            watcher.watchFile(path)

            try "1".write(toFile: path, atomically: true, encoding: .utf8)

            #expect(await reader.next(.fileChanged(path)) != nil)
            watcher.stop()
        }

        @Test func `a suppressed file reports nothing while another still does`() async throws {
            let tree = try TempTree()
            try tree.createFile(named: "mine.txt", content: "0")
            try tree.createFile(named: "theirs.txt", content: "0")
            let mine = tree.root + "/mine.txt"
            let theirs = tree.root + "/theirs.txt"
            let watcher = try KqueueWatcher(suppressionWindow: .seconds(3_600), stopped: nil)
            var reader = EventReader(watcher)
            watcher.watchFile(mine)
            watcher.watchFile(theirs)
            watcher.suppressNotifications(for: mine)

            try overwrite(mine, "1")
            try overwrite(theirs, "1")

            #expect(await reader.next(.fileChanged(theirs)) != nil)
            #expect(!reader.seen.contains(.fileChanged(mine)))
            watcher.stop()
        }

        @Test func `an unwatched file reports nothing more`() async throws {
            let tree = try TempTree()
            try tree.createFile(named: "closed.txt", content: "0")
            try tree.createFile(named: "open.txt", content: "0")
            let closed = tree.root + "/closed.txt"
            let open = tree.root + "/open.txt"
            let watcher = try KqueueWatcher()
            var reader = EventReader(watcher)
            watcher.watchFile(closed)
            watcher.watchFile(open)
            watcher.unwatchFile(closed)

            try overwrite(closed, "1")
            try overwrite(open, "1")

            #expect(await reader.next(.fileChanged(open)) != nil)
            #expect(!reader.seen.contains(.fileChanged(closed)))
            watcher.stop()
        }

        @Test func `stopping finishes the stream, and the thread closes the queue it opened`() async throws {
            let closed = try await withCheckedThrowingContinuation { (done: CheckedContinuation<Bool, any Error>) in
                do {
                    let watcher = try KqueueWatcher(
                        suppressionWindow: .seconds(1), stopped: { done.resume(returning: $0) })
                    watcher.watchDirectory(NSTemporaryDirectory())
                    watcher.stop()
                } catch {
                    done.resume(throwing: error)
                }
            }
            #expect(closed, "the kqueue descriptor was open, and is closed exactly once")
        }

        @Test func `a released watcher stops its thread`() async throws {
            let closed = try await withCheckedThrowingContinuation { (done: CheckedContinuation<Bool, any Error>) in
                do {
                    _ = try KqueueWatcher(suppressionWindow: .seconds(1), stopped: { done.resume(returning: $0) })
                } catch {
                    done.resume(throwing: error)
                }
            }
            #expect(closed)
        }

        @Test func `the event stream finishes after stop`() async throws {
            let watcher = try KqueueWatcher()
            watcher.stop()
            var iterator = watcher.events.makeAsyncIterator()
            #expect(await iterator.next() == nil)
        }
    }

    @Suite(.tags(.fileWatcher), .timeLimit(.minutes(1)))
    struct DirectoryWatchTests {
        @Test func `a change to the directory ends the wait with true`() async throws {
            let tree = try TempTree()
            let watch = try #require(DirectoryWatch(directory: tree.root))
            defer { watch.close() }
            let changed = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
                DetachedThread.start(stackBytes: 64 << 10) { done.resume(returning: watch.next()) }
                try? tree.createFile(named: "new.txt")
            }
            #expect(changed)
        }

        @Test func `a wake ends the wait with false, and both descriptors close once`() async throws {
            let tree = try TempTree()
            let watch = try #require(DirectoryWatch(directory: tree.root))
            let woken = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
                DetachedThread.start(stackBytes: 64 << 10) { done.resume(returning: watch.next()) }
                watch.wake()
            }
            #expect(!woken)
            let closed = watch.close()
            #expect(closed.queue && closed.directory)
        }

        @Test func `a missing directory cannot be watched`() {
            #expect(DirectoryWatch(directory: "/nonexistent-\(UUID().uuidString)") == nil)
        }
    }

    struct FileIdentityTests {
        @Test func `an atomic save is another file, a write in place the same file changed`() throws {
            let tree = try TempTree()
            try tree.createFile(named: "f", content: "one")
            let path = tree.root + "/f"
            let first = try #require(FileIdentity(path: path))
            try tree.createFile(named: "f", content: "two, longer")
            let saved = try #require(FileIdentity(path: path))
            #expect(!saved.isSameFile(as: first))
            let handle = try #require(FileHandle(forWritingAtPath: path))
            try handle.write(contentsOf: Data("three, longer still".utf8))
            try handle.close()
            let written = try #require(FileIdentity(path: path))
            #expect(written.isSameFile(as: saved))
            #expect(written != saved)
            #expect(written.path == CanonicalPath.of(path))
        }

        @Test func `nothing at the path has no identity`() {
            #expect(FileIdentity(path: "/nonexistent-\(UUID().uuidString)") == nil)
        }
    }
#endif

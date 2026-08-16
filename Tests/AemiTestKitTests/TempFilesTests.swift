import Foundation
import SystemPackage
import Testing

@testable import AemiTestKit

struct TempFilesTests {
    private var fm: FileManager { .default }

    @Test
    func `TemporaryDirectory creates a real, private, owner-only directory`() {
        let dir = TemporaryDirectory()
        defer { dir.cleanup() }

        var isDir: ObjCBool = false
        #expect(fm.fileExists(atPath: dir.path, isDirectory: &isDir))
        #expect(isDir.boolValue)
        // mkdtemp creates with 0700 — the owner-only property we rely on.
        let perms = try? fm.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int
        #expect(perms == 0o700)
    }

    @Test
    func `each TemporaryDirectory is unique`() {
        let a = TemporaryDirectory()
        let b = TemporaryDirectory()
        defer {
            a.cleanup()
            b.cleanup()
        }
        #expect(a.path != b.path)
    }

    @Test
    func `file(_:) and filePath(_:) join inside the directory`() {
        let dir = TemporaryDirectory()
        defer { dir.cleanup() }
        #expect(dir.file("data.db") == dir.path + "/data.db")
        #expect(dir.filePath("data.db") == FilePath(dir.path).appending("data.db"))
    }

    // The regression that motivated the rewrite: the previous cleanup() only `unlink`ed
    // top-level entries, so a subdirectory (and the file in it) leaked and rmdir failed.
    @Test
    func `cleanup recursively removes nested subdirectories and files`() throws {
        let dir = TemporaryDirectory()
        let nested = dir.file("sub/deeper")
        try fm.createDirectory(atPath: nested, withIntermediateDirectories: true)
        // Assert the create succeeded — also required on Linux, where corelibs-foundation's
        // `createFile` is not `@discardableResult` (unused result = error under -warnings-as-errors).
        #expect(fm.createFile(atPath: dir.file("sub/leaf.txt"), contents: Data("x".utf8)))
        #expect(fm.fileExists(atPath: nested))

        dir.cleanup()
        #expect(!fm.fileExists(atPath: dir.path))  // whole tree gone — no leak
    }

    @Test
    func `cleanup is safe to call twice / on a missing directory`() {
        let dir = TemporaryDirectory()
        dir.cleanup()
        dir.cleanup()  // must not trap
        #expect(!fm.fileExists(atPath: dir.path))
    }

    @Test
    func `withTemporaryDirectory cleans up even when body throws`() {
        struct Boom: Error {}
        var captured = ""
        #expect(throws: Boom.self) {
            try TemporaryDirectory.withTemporaryDirectory { dir in
                captured = dir.path
                #expect(FileManager.default.fileExists(atPath: dir.path))
                throw Boom()
            }
        }
        #expect(!captured.isEmpty)
        #expect(!fm.fileExists(atPath: captured))
    }

    @Test
    func `withTemporaryFilePath vends a path and removes the file plus engine siblings`() {
        var dbPath = ""
        withTemporaryFilePath(extension: "db") { path in
            dbPath = path
            // The engine would create the db plus -wal/-shm siblings next to it. Assert each
            // create — also required on Linux, where corelibs-foundation's `createFile` is not
            // `@discardableResult` (unused result = error under -warnings-as-errors).
            #expect(fm.createFile(atPath: path, contents: Data("db".utf8)))
            #expect(fm.createFile(atPath: path + "-wal", contents: Data("wal".utf8)))
            #expect(fm.createFile(atPath: path + "-shm", contents: Data()))
            #expect(fm.fileExists(atPath: path))
        }
        #expect(!dbPath.isEmpty)
        #expect(dbPath.hasSuffix(".db"))
        // The whole private directory is gone, so the file and every sibling are too.
        #expect(!fm.fileExists(atPath: dbPath))
        #expect(!fm.fileExists(atPath: dbPath + "-wal"))
        #expect(!fm.fileExists(atPath: dbPath + "-shm"))
    }
}

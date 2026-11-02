import Foundation
import Testing

@testable import AemiIO

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// A fresh directory under the system temp directory, removed by the caller.
private func scratchDirectory() throws -> String {
    let path = NSTemporaryDirectory() + "aemi-io-\(getpid())-\(UInt64.random(in: 0 ..< .max))"
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
    return path
}

private func contents(_ path: String) throws -> [UInt8] {
    [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
}

@Suite struct ExclusiveCreationTests {
    @Test func `an exclusive creation refuses an existing file and a dangling link`() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let file = directory + "/file"
        let created = try PosixFile(creatingExclusively: file)
        created.close()
        #expect(throws: IOError.self) { try PosixFile(creatingExclusively: file) }
        let link = directory + "/link"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: directory + "/missing")
        do {
            _ = try PosixFile(creatingExclusively: link)
            Issue.record("a dangling link was followed")
        } catch {
            #expect(error.errno == EEXIST)
        }
        #expect(!FileManager.default.fileExists(atPath: directory + "/missing"))
    }

    @Test func `safe writes and reads round-trip, and a short read is an error`() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let file = try PosixFile(creatingExclusively: directory + "/data")
        defer { file.close() }
        try file.write(Array("hello, world".utf8), at: 0)
        try file.write(Array("WORLD!".utf8)[0 ..< 5], at: 7)
        #expect(try file.read(at: 0, count: 12) == Array("hello, WORLD".utf8))
        #expect(try file.read(at: 3, count: 0) == [])
        #expect(throws: IOError.self) { try file.read(at: 10, count: 5) }
    }
}

@Suite struct AtomicFileTests {
    @Test func `a replacement creates, then replaces, and leaves no temporary file`() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = directory + "/state.json"
        try AtomicFile.replace(at: path, with: Array("one".utf8))
        #expect(try contents(path) == Array("one".utf8))
        try AtomicFile.replace(at: path, with: Array("two, longer".utf8), durability: .barrier, permissions: 0o600)
        #expect(try contents(path) == Array("two, longer".utf8))
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory) == ["state.json"])
    }

    @Test func `a failed replacement leaves the target as it was`() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        // The target is a directory with an entry: rename refuses to replace it.
        let target = directory + "/occupied"
        try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: URL(fileURLWithPath: target + "/entry"))
        #expect(throws: IOError.self) { try AtomicFile.replace(at: target, with: Array("new".utf8)) }
        #expect(try contents(target + "/entry") == Array("keep".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory) == ["occupied"])
        #expect(throws: IOError.self) {
            try AtomicFile.replace(at: directory + "/missing/file", with: [1])
        }
    }

    @Test func `paths split into a directory and a name`() {
        #expect(AtomicFile.split("/a/b/c") == ("/a/b", "c"))
        #expect(AtomicFile.split("/c") == ("/", "c"))
        #expect(AtomicFile.split("c") == (".", "c"))
    }
}

@Suite struct FileCopyTests {
    @Test func `a copy keeps the bytes and the mode, and clones on APFS`() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let source = directory + "/source"
        let bytes = (0 ..< 3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 7) }
        try Data(bytes).write(to: URL(fileURLWithPath: source))
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: source)
        let method = try FileCopy.copy(from: source, to: directory + "/clone")
        #expect(try contents(directory + "/clone") == bytes)
        #expect(
            (try FileManager.default.attributesOfItem(atPath: directory + "/clone")[.posixPermissions] as? Int) == 0o640
        )
        #if os(macOS)
            #expect(method == .cloned)  // the temporary directory is on APFS
        #endif
        // The read-and-write path, as on a volume without clones.
        try FileCopy.copyBytes(from: source, to: directory + "/copy", permissions: 0o600)
        #expect(try contents(directory + "/copy") == bytes)
    }

    @Test func `a copy refuses a link, a directory and an existing destination`() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let source = directory + "/source"
        try Data("x".utf8).write(to: URL(fileURLWithPath: source))
        try FileManager.default.createSymbolicLink(atPath: directory + "/link", withDestinationPath: source)
        func errno(_ body: () throws -> Void) -> Int32? {
            do { try body() } catch { return (error as? IOError)?.errno }
            return nil
        }
        #expect(errno { _ = try FileCopy.copy(from: directory + "/link", to: directory + "/a") } == ELOOP)
        #expect(errno { _ = try FileCopy.copy(from: directory, to: directory + "/b") } == EINVAL)
        try Data("y".utf8).write(to: URL(fileURLWithPath: directory + "/taken"))
        #expect(errno { _ = try FileCopy.copy(from: source, to: directory + "/taken") } == EEXIST)
        #expect(errno { try FileCopy.copyBytes(from: source, to: directory + "/taken", permissions: 0o644) } == EEXIST)
        #expect(try contents(directory + "/taken") == Array("y".utf8))
        #expect(!FileManager.default.fileExists(atPath: directory + "/a"))
    }
}

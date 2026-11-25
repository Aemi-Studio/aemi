import AemiIO
import Foundation
import Testing

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

@Suite struct FileLockTests {
    @Test func `non-blocking exclusive lock rejects a second lock and releases cleanly`() throws {
        let dir = NSTemporaryDirectory() + "aemi-filelock-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/test.lock"

        let first = try FileLock(path: path, mode: .exclusiveNonBlocking)
        do {
            _ = try FileLock(path: path, mode: .exclusiveNonBlocking)
            Issue.record("expected second non-blocking exclusive lock to fail")
        } catch {
            #expect(error.errno == EWOULDBLOCK || error.errno == EAGAIN)
        }
        first.release()
        first.release()

        let value = try FileLock.withLock(at: path, mode: .exclusiveNonBlocking) { 42 }
        #expect(value == 42)
    }

    @Test func `shared locks coexist while exclusive lock fails`() throws {
        let dir = NSTemporaryDirectory() + "aemi-filelock-shared-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/shared.lock"

        let s1 = try FileLock(path: path, mode: .sharedNonBlocking)
        let s2 = try FileLock(path: path, mode: .sharedNonBlocking)
        defer {
            s2.release()
            s1.release()
        }
        do {
            _ = try FileLock(path: path, mode: .exclusiveNonBlocking)
            Issue.record("exclusive lock must fail while shared locks are held")
        } catch {
            #expect(error.errno == EWOULDBLOCK || error.errno == EAGAIN)
        }
    }
}

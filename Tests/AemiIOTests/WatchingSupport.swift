import Foundation
import Testing

@testable import AemiIO

/// A scratch directory removed when released.
final class TempTree: Sendable {
    let root: String

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "aemiio-watch-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    /// Writes `content` to `name` below the root, atomically: a new file renamed over any old one.
    func createFile(named name: String, content: String = "") throws {
        try content.write(toFile: root + "/" + name, atomically: true, encoding: .utf8)
    }

    func createDirectory(named name: String) throws {
        try FileManager.default.createDirectory(atPath: root + "/" + name, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: root)
    }
}

/// Reads one watcher's events in order. Every wait ends on an event, never on a timer: the suite's time limit fails a
/// test whose event never comes.
struct EventReader {
    private var iterator: AsyncStream<FileWatchEvent>.Iterator
    /// Every event read so far, in arrival order.
    private(set) var seen: [FileWatchEvent] = []

    init(_ watcher: some FileWatching) {
        iterator = watcher.events.makeAsyncIterator()
    }

    /// Reads up to the first event equal to `expected` and returns it, or nil when the stream finishes first.
    mutating func next(_ expected: FileWatchEvent) async -> FileWatchEvent? {
        await next { $0 == expected }
    }

    /// Reads up to the first event `matches` accepts and returns it, or nil when the stream finishes first.
    mutating func next(where matches: (FileWatchEvent) -> Bool) async -> FileWatchEvent? {
        while let event = await iterator.next() {
            seen.append(event)
            if matches(event) { return event }
        }
        return nil
    }

    /// Writes `marker` next to the watched files and reads up to `marking`, the event it raises. Events arrive in order,
    /// so every event of an earlier write has been read by then.
    mutating func settle(writing marker: String, marking: FileWatchEvent) async throws -> FileWatchEvent? {
        try Data().write(to: URL(fileURLWithPath: marker))
        return await next(marking)
    }
}

extension Tag {
    @Tag static var fileWatcher: Self
}

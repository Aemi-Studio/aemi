/// What a file watcher offers, whichever kernel facility it rests on: ``FileWatcher`` (FSEvents, whole trees, macOS) and
/// ``KqueueWatcher`` (kqueue, one directory level, every Apple platform). Code that only needs to hear about changes
/// takes `some FileWatching`, so the backend is a choice made once, and a test can substitute its own.
///
/// ``events`` is one stream for the watcher's lifetime, read by one consumer. A consumer that needs several kinds of
/// change routes them itself, by path.
public protocol FileWatching: Sendable {
    /// Every change, until ``stop()``.
    var events: AsyncStream<FileWatchEvent> { get }
    /// Reports later changes in the directory at `path`. How deep is the backend's: see each conformer.
    func watchDirectory(_ path: String) async
    /// Reports later changes to the file at `path` as ``FileWatchEvent/fileChanged(_:)`` carrying `path` itself, through
    /// atomic saves that rename a new file over it, and whether or not the file exists yet.
    func watchFile(_ path: String) async
    /// Stops reporting `path` as a watched file.
    func unwatchFile(_ path: String) async
    /// Marks `path` as written by the caller, so events for it in the next moment are dropped rather than reported as
    /// someone else's change.
    func suppressNotifications(for path: String)
    /// Stops watching and finishes ``events``.
    func stop() async
}

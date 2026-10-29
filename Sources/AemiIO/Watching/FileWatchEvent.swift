/// A change a file watcher reports.
///
/// Either kind is a reason to look again, not a description of what happened: a watcher coalesces events, one save can
/// raise several, and a watcher that lost track reports everything it watches once more.
public enum FileWatchEvent: Sendable, Hashable {
    /// A watched file may have changed: it was written, replaced, renamed, created or removed, or the watcher lost track
    /// of it. The path is the one given to ``FileWatching/watchFile(_:)``.
    case fileChanged(String)
    /// Something else changed in a watched directory or next to a watched file. The path is canonical
    /// (``CanonicalPath/of(_:)``). ``FileWatcher`` names the entry that changed; ``KqueueWatcher`` names the directory,
    /// since kqueue does not say which entry it was.
    case directoryChanged(String)
}

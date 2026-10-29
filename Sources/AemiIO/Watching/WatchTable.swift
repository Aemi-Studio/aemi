#if os(macOS)
    import CoreServices

    /// What one ``FileWatcher`` watches, and how FSEvents' raw events map onto ``FileWatchEvent``s.
    struct WatchTable: Sendable, Equatable {
        /// How the watcher answers one raw FSEvents event.
        enum Route: Equatable {
            /// Report nothing: FSEvents' end-of-history marker, an event older than its watch, or a suppressed path.
            case skip
            /// Report ``FileWatchEvent/fileChanged(_:)`` for each of these registered paths.
            case files([String])
            /// Report ``FileWatchEvent/directoryChanged(_:)`` for this canonical path.
            case directory(String)
            /// FSEvents coalesced or dropped the events below this path: report everything watched there.
            case rescan(String)
        }

        /// A canonical path a watched file answers to.
        struct FileKey: Sendable, Equatable {
            /// The paths the caller registered for this key, in the order it watched them.
            var registered: [String]
            /// The directory whose events carry this key's changes.
            var parent: String
            /// The system's event ID when the earliest of `registered` was watched.
            var since: FSEventStreamEventId
        }

        /// Canonical directories the caller asked to watch, each with the system's event ID when it asked.
        private(set) var directories: [String: FSEventStreamEventId] = [:]
        /// The watched files' canonical keys.
        private(set) var fileKeys: [String: FileKey] = [:]
        /// Canonical directories FSEvents filters out.
        var exclusions: [String] = []
        /// The latest `since` of any watch: every event after it is new to every watch.
        private(set) var newestSince: FSEventStreamEventId = 0

        /// The fewest directories covering `directories` and each watched file's parent, sorted: the stream's paths.
        /// - Complexity: O(w²) in the watched directories and files.
        var roots: [String] {
            CanonicalPath.minimalCover(Array(directories.keys) + fileKeys.values.map(\.parent))
        }

        /// Watches canonical `directory` from event `since` on.
        /// - Returns: False when `directory` was already watched, which leaves it watched from its first `since`.
        mutating func insertDirectory(_ directory: String, since: FSEventStreamEventId) -> Bool {
            guard directories[directory] == nil else { return false }
            directories[directory] = since
            newestSince = max(newestSince, since)
            return true
        }

        /// Reports `registered` for each of its canonical `keys` from event `since` on.
        mutating func insertFile(_ registered: String, keys: [String], since: FSEventStreamEventId) {
            for key in keys {
                if fileKeys[key] == nil {
                    fileKeys[key] = FileKey(registered: [], parent: CanonicalPath.parent(of: key), since: since)
                }
                fileKeys[key]?.registered.append(registered)
            }
            newestSince = max(newestSince, since)
        }

        /// Stops reporting `registered` for its canonical `keys`, dropping each key no other path answers to.
        mutating func removeFile(_ registered: String, keys: [String]) {
            for key in keys {
                fileKeys[key]?.registered.removeAll { $0 == registered }
                if fileKeys[key]?.registered.isEmpty == true {
                    fileKeys[key] = nil
                }
            }
        }

        /// How to answer one raw event at canonical `path`.
        /// - Parameters:
        ///   - path: The canonical path FSEvents reported.
        ///   - flags: The event's `kFSEventStreamEventFlag…` bits.
        ///   - id: The event's system-wide ID.
        ///   - isSuppressed: Whether the app wrote `path` itself moments ago.
        /// - Returns: What to report for the event.
        func route(
            path: String, flags: FSEventStreamEventFlags, id: FSEventStreamEventId, isSuppressed: (String) -> Bool
        ) -> Route {
            if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) != 0 { return .skip }
            if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0 { return .rescan(path) }
            if isStale(path, id: id) || isSuppressed(path) { return .skip }
            if let key = fileKeys[path] { return .files(key.registered) }
            return .directory(path)
        }

        /// Whether event `id` at `path` predates every watch covering `path`, or no watch covers it. A restarted stream
        /// replays history from before its restart, and such events in it are stale news.
        /// - Complexity: O(1) for an event newer than every watch, else O(w) in the watched directories and files.
        func isStale(_ path: String, id: FSEventStreamEventId) -> Bool {
            guard id <= newestSince else { return false }
            var earliest: FSEventStreamEventId?
            for (directory, since) in directories where CanonicalPath.isInside(path, directory) {
                earliest = min(earliest ?? since, since)
            }
            for key in fileKeys.values where CanonicalPath.isInside(path, key.parent) {
                earliest = min(earliest ?? key.since, key.since)
            }
            guard let earliest else { return true }
            return id <= earliest
        }

        /// The events that make a consumer rescan below `path`: every watched file there, then `path` itself when the
        /// stream covers it, else each watched directory below it. `/` lists everything watched.
        /// - Complexity: O(w log w) in the watched directories and files.
        func rescanEvents(below path: String) -> [FileWatchEvent] {
            var events: [FileWatchEvent] = []
            for (key, file) in fileKeys.sorted(by: { $0.key < $1.key }) where CanonicalPath.isInside(key, path) {
                events += file.registered.map(FileWatchEvent.fileChanged)
            }
            if roots.contains(where: { CanonicalPath.isInside(path, $0) }) {
                events.append(.directoryChanged(path))
            } else {
                events += directories.keys.sorted().filter { CanonicalPath.isInside($0, path) }
                    .map(FileWatchEvent.directoryChanged)
            }
            return events
        }
    }
#endif

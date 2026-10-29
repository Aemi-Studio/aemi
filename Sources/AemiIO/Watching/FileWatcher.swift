#if os(macOS)
    import CoreServices

    /// Watches directory trees and individual files through one FSEvents stream, surfacing both as one consumer-driven
    /// `AsyncStream`.
    ///
    /// Every watched directory, and the parent directory of every watched file, joins a single stream. A call that
    /// changes that set restarts the stream from the last event the old one delivered, so no change made in between is
    /// lost. Paths are keyed by `realpath(3)`, the spelling FSEvents reports (`/tmp/a` arrives as `/private/tmp/a`), and
    /// a file watch follows its path, not its inode, so it survives the atomic saves that rename a new file over it.
    ///
    /// Against ``KqueueWatcher``: whole trees, any number of paths on one stream, history replayed across restarts, and
    /// directory events that name the entry; at the price of FSEvents' coalescing delay (`latency`) and macOS only.
    ///
    /// FSEvents calls back on the watcher's serial queue and yields straight to the stream's continuation, so the
    /// watcher starts no task of its own.
    public actor FileWatcher: FileWatching {
        /// The event type, under the name this watcher's first users wrote.
        public typealias FileWatchEvent = AemiIO.FileWatchEvent

        /// Why ``excludeDirectories(_:)`` refused its paths.
        public enum ExclusionError: Error, Equatable {
            /// FSEvents takes at most ``FileWatcher/maximumExcludedDirectories`` paths; the payload is how many were given.
            case tooManyDirectories(Int)
        }

        /// The most directories ``excludeDirectories(_:)`` accepts: FSEvents' own limit.
        public static let maximumExcludedDirectories = 8
        /// How many events wait for a consumer that falls behind. Past it the oldest are dropped, and the watcher then
        /// reports every watched file and directory once more, so a slow consumer rescans instead of missing a change.
        public static let eventBufferLimit = 1_024

        public nonisolated let events: AsyncStream<FileWatchEvent>
        private nonisolated let continuation: AsyncStream<FileWatchEvent>.Continuation
        private nonisolated let epoch: ContinuousClock.Instant
        private nonisolated let suppression: SuppressionWindow
        private nonisolated let stream: FSEventStreamController
        private var table = WatchTable()
        /// Each watched file's registered path, with the canonical keys its events arrive under.
        private var watchedFiles: [String: [String]] = [:]
        private var isStopped = false

        /// - Parameters:
        ///   - latency: How long FSEvents coalesces events before delivering them, in seconds.
        ///   - onFailure: Told, on the watcher's queue, when FSEvents refuses a stream or its exclusions; the watcher
        ///     then reports nothing for those paths until the next change to what it watches.
        public init(latency: Double = 0.1, onFailure: @escaping @Sendable (String) -> Void = { _ in }) {
            self.init(latency: latency, suppressionWindow: .seconds(1), onFailure: onFailure)
        }

        /// - Parameters:
        ///   - latency: How long FSEvents coalesces events before delivering them, in seconds.
        ///   - suppressionWindow: How long ``suppressNotifications(for:)`` silences a path.
        ///   - onFailure: Told when FSEvents refuses a stream or its exclusions.
        init(
            latency: Double, suppressionWindow: Duration, onFailure: @escaping @Sendable (String) -> Void = { _ in }
        ) {
            let (events, continuation) = AsyncStream.makeStream(
                of: FileWatchEvent.self, bufferingPolicy: .bufferingNewest(Self.eventBufferLimit))
            let epoch = ContinuousClock.now
            let suppression = SuppressionWindow(window: suppressionWindow)
            self.events = events
            self.continuation = continuation
            self.epoch = epoch
            self.suppression = suppression
            self.stream = FSEventStreamController(
                latency: latency, continuation: continuation, suppression: suppression, epoch: epoch,
                onFailure: onFailure)
        }

        /// Reports every later change below `path`. Several directories share one stream, restarted over their union
        /// with no event lost. Does nothing for a directory already watched, or after ``stop()``.
        /// - Complexity: O(w²) in the watched directories and files, to recompute the stream's paths.
        public func watchDirectory(_ path: String) {
            let requestedAt = FSEventsGetCurrentEventId()
            guard !isStopped, table.insertDirectory(CanonicalPath.of(path), since: requestedAt) else { return }
            stream.apply(table, requestedAt: requestedAt)
        }

        /// Reports later changes to the file at `path` as ``FileWatchEvent/fileChanged(_:)`` carrying `path` itself.
        /// The watch listens to the parent directory, so it outlives atomic saves, and the file need not exist yet; the
        /// siblings' changes arrive as ``FileWatchEvent/directoryChanged(_:)``. Does nothing for a file already
        /// watched, or after ``stop()``.
        /// - Complexity: O(w²) in the watched directories and files, to recompute the stream's paths.
        public func watchFile(_ path: String) {
            let requestedAt = FSEventsGetCurrentEventId()
            guard !isStopped, watchedFiles[path] == nil else { return }
            let keys = CanonicalPath.keys(forFile: path)
            watchedFiles[path] = keys
            table.insertFile(path, keys: keys, since: requestedAt)
            stream.apply(table, requestedAt: requestedAt)
        }

        /// Stops reporting `path` as a watched file: its later changes arrive as directory changes while its directory
        /// stays watched for another reason.
        /// - Complexity: O(w²) in the watched directories and files, to recompute the stream's paths.
        public func unwatchFile(_ path: String) {
            let requestedAt = FSEventsGetCurrentEventId()
            guard let keys = watchedFiles.removeValue(forKey: path) else { return }
            table.removeFile(path, keys: keys)
            stream.apply(table, requestedAt: requestedAt)
        }

        /// Filters every change below each of `paths` out of the stream, inside FSEvents, replacing earlier exclusions.
        /// A watched file below an excluded directory goes silent too. Does nothing after ``stop()``.
        /// - Parameter paths: At most ``maximumExcludedDirectories`` directories.
        /// - Throws: ``ExclusionError/tooManyDirectories(_:)`` when `paths` holds more, leaving the exclusions unchanged.
        public func excludeDirectories(_ paths: [String]) throws(ExclusionError) {
            guard paths.count <= Self.maximumExcludedDirectories else { throw .tooManyDirectories(paths.count) }
            let requestedAt = FSEventsGetCurrentEventId()
            guard !isStopped else { return }
            table.exclusions = paths.map(CanonicalPath.of)
            stream.apply(table, requestedAt: requestedAt)
        }

        /// Marks `path` as written by the caller, so events of either kind for it in the next second are dropped rather
        /// than reported as external changes. Callable from any isolation without an `await`.
        public nonisolated func suppressNotifications(for path: String) {
            let now = epoch.duration(to: ContinuousClock.now)
            for key in CanonicalPath.keys(forFile: path) {
                suppression.record(key, now: now)
            }
        }

        /// The canonical paths under which events for the file at `path` arrive: its `realpath(3)` target and, when
        /// `path` is a symlink, the link's own location. A consumer that matches ``FileWatchEvent/directoryChanged(_:)``
        /// paths to its own files compares against these.
        public static func canonicalPaths(forFile path: String) -> [String] {
            CanonicalPath.keys(forFile: path)
        }

        /// Stops watching and finishes ``events``; the watch methods do nothing afterwards.
        public func stop() {
            guard !isStopped else { return }
            isStopped = true
            watchedFiles.removeAll()
            table = WatchTable()
            stream.invalidate()
            continuation.finish()
        }

        /// Returns once the stream has applied every earlier watch, unwatch and exclusion, so a test's next write lands
        /// in the stream those calls configured.
        func synchronizeStream() async {
            await stream.synchronize()
        }

        deinit {
            stream.invalidate()
            continuation.finish()
        }
    }
#endif

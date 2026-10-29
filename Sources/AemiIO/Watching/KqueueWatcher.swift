#if canImport(Darwin)
    import Darwin
    internal import Synchronization

    /// Watches files and single directories with one kqueue, on one thread of its own, surfacing every change as one
    /// consumer-driven `AsyncStream`.
    ///
    /// - A file is followed by its **path**: the watcher holds its parent directory open, so an atomic save that renames
    ///   a new file over it is seen, and it holds the file itself open, so a write in place is seen too.
    /// - A file whose directory does not exist yet is anchored on the nearest directory that does, and moves down as the
    ///   missing ones appear: watching `project/.ask/config.json` before `.ask` exists works.
    /// - A directory is watched **one level deep**: entries added, removed or renamed in it. kqueue cannot watch a tree;
    ///   ``FileWatcher`` (FSEvents, macOS) can.
    ///
    /// Against ``FileWatcher``: no coalescing delay and no daemon in between, so a change arrives at once; one descriptor
    /// per watched file and directory, so it suits a handful of paths, not a source tree. Measured at idle: one 64 KiB
    /// thread and about 64 KiB of memory for two directories.
    public final class KqueueWatcher: FileWatching {
        /// How many events wait for a consumer that falls behind. Past it the oldest are dropped, and the watcher then
        /// reports everything it watches once more, so a slow consumer rescans instead of missing a change.
        public static let eventBufferLimit = 1_024

        public let events: AsyncStream<FileWatchEvent>
        private let loop: KqueueEventLoop

        /// A watcher with its thread started.
        /// - Throws: ``IOError`` when the system refuses the kqueue or the thread.
        public convenience init() throws(IOError) {
            try self.init(suppressionWindow: .seconds(1), stopped: nil)
        }

        /// - Parameters:
        ///   - suppressionWindow: How long ``suppressNotifications(for:)`` silences a path.
        ///   - stopped: Called once on the watcher's thread after it closed everything, with whether the queue's
        ///     `close` succeeded. For tests.
        /// - Throws: ``IOError`` when the system refuses the kqueue or the thread.
        init(suppressionWindow: Duration, stopped: (@Sendable (Bool) -> Void)?) throws(IOError) {
            let (events, continuation) = AsyncStream.makeStream(
                of: FileWatchEvent.self, bufferingPolicy: .bufferingNewest(Self.eventBufferLimit))
            guard let queue = KernelQueue() else { throw IOError.capturingErrno("kqueue") }
            let loop = KqueueEventLoop(
                queue: queue, continuation: continuation, suppression: SuppressionWindow(window: suppressionWindow),
                stopped: stopped)
            guard DetachedThread.start(stackBytes: 64 << 10, loop.run) else {
                queue.close()
                throw IOError.capturingErrno("pthread_create")
            }
            self.events = events
            self.loop = loop
        }

        deinit {
            loop.stop()
        }

        /// Reports later changes to the entries directly inside `path`, as ``FileWatchEvent/directoryChanged(_:)``
        /// naming the directory. Nothing happens for a directory that cannot be opened. A watched directory that is
        /// removed or renamed is reported once and then no longer watched.
        public func watchDirectory(_ path: String) {
            loop.update { state, queue in state.watchDirectory(CanonicalPath.of(path), queue: queue) }
        }

        /// Reports later changes to the file at `path`, however it is saved, and its creation if it does not exist yet.
        public func watchFile(_ path: String) {
            loop.update { state, queue in state.watchFile(path, queue: queue) }
        }

        /// Stops reporting the file at `path`, and closes what was held open only for it.
        public func unwatchFile(_ path: String) {
            loop.update { state, _ in state.unwatchFile(path) }
        }

        /// Drops events for the file at `path`, and for `path` as a directory, for the next second. A write inside a
        /// watched directory still reports the directory, which names no entry.
        public func suppressNotifications(for path: String) {
            loop.suppress(path)
        }

        /// Stops watching and finishes ``events``. The thread closes every descriptor as it ends.
        public func stop() {
            loop.stop()
        }
    }

    /// The thread side of a ``KqueueWatcher``: its state behind a lock, and the loop that waits in `kevent`.
    ///
    /// Only the loop closes the queue, after its last wait, and under the lock with `isStopped` set, so a wake can never
    /// reach a closed descriptor's number.
    final class KqueueEventLoop: Sendable {
        private let queue: KernelQueue
        private let continuation: AsyncStream<FileWatchEvent>.Continuation
        private let suppression: SuppressionWindow
        private let epoch = ContinuousClock.now
        private let state = Mutex(KqueueWatchState())
        private let stopped: (@Sendable (Bool) -> Void)?

        init(
            queue: KernelQueue, continuation: AsyncStream<FileWatchEvent>.Continuation, suppression: SuppressionWindow,
            stopped: (@Sendable (Bool) -> Void)?
        ) {
            self.queue = queue
            self.continuation = continuation
            self.suppression = suppression
            self.stopped = stopped
        }

        func update(_ change: (inout KqueueWatchState, KernelQueue) -> Void) {
            state.withLock { state in
                guard !state.isStopped else { return }
                change(&state, queue)
            }
        }

        func suppress(_ path: String) {
            let now = epoch.duration(to: .now)
            for key in Set(CanonicalPath.keys(forFile: path) + [CanonicalPath.of(path)]) {
                suppression.record(key, now: now)
            }
        }

        func stop() {
            state.withLock { state in
                guard !state.isStopped else { return }
                state.isStopped = true
                queue.wake()
            }
            continuation.finish()
        }

        /// Waits for events and reports them until stopped or the queue fails, then closes everything.
        @Sendable func run() {
            while true {
                let batch = queue.wait()
                let changes: [FileWatchEvent]? = state.withLock { state in
                    guard !batch.isEmpty, !state.isStopped else { return nil }
                    let now = epoch.duration(to: .now)
                    return batch.filter { $0.tag != KernelQueue.wakeTag }
                        .flatMap { state.handle($0, queue: queue) }
                        .filter { !state.isSuppressed($0) { suppression.isSuppressed($0, now: now) } }
                }
                guard let changes else { break }
                publish(changes)
            }
            let closed = state.withLock { state in
                state.isStopped = true
                state.closeAll()
                return queue.close()
            }
            continuation.finish()
            stopped?(closed)
        }

        /// Yields `changes`; when the buffer dropped any, everything watched once more, at the end, where the buffer
        /// keeps it.
        private func publish(_ changes: [FileWatchEvent]) {
            var overflowed = false
            for change in changes {
                if case .dropped = continuation.yield(change) { overflowed = true }
            }
            guard overflowed else { return }
            for change in state.withLock({ $0.everything() }) {
                continuation.yield(change)
            }
        }
    }
#endif

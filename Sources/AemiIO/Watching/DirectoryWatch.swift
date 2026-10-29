#if canImport(Darwin)
    import Darwin

    /// A blocking wait for one directory to change: an entry added, removed or renamed. For a one-off wait on a thread
    /// of the caller's ("until this file appears"); ``KqueueWatcher`` is the long-lived, many-path form.
    ///
    /// A file saved by writing a new one and renaming it over the old shows up as a change to the *directory*; the old
    /// file's own descriptor only sees a deletion. So waits for a file watch its directory and look again on each change.
    ///
    /// ``next()`` blocks, so it belongs on a thread of its own, never on the cooperative pool.
    public struct DirectoryWatch: Sendable {
        private let queue: KernelQueue
        private let directory: Int32

        /// Opens `path`, a directory, and registers for its changes; nil if either step fails.
        public init?(directory path: String) {
            guard let queue = KernelQueue() else { return nil }
            guard let directory = queue.register(path: path, notes: KernelQueue.directoryFlags, tag: 2) else {
                queue.close()
                return nil
            }
            self.queue = queue
            self.directory = directory
        }

        /// Blocks until the directory changes.
        /// - Returns: true for a change; false when ``wake()`` ended the wait, or the queue failed.
        public func next() -> Bool {
            queue.wait(limit: 1).first.map { $0.tag != KernelQueue.wakeTag } ?? false
        }

        /// Ends a blocked ``next()``, which then returns false. Not after ``close()``: the descriptor's number could
        /// belong to something else by then.
        public func wake() {
            queue.wake()
        }

        /// Closes both descriptors.
        /// - Returns: whether each `close` succeeded, which means it was open and is closed exactly once. For tests: a
        ///   descriptor's number may be reused by another thread at once, so asking afterwards whether it is open would
        ///   race.
        @discardableResult
        public func close() -> (queue: Bool, directory: Bool) {
            (queue.close(), Darwin.close(directory) == 0)
        }
    }
#endif

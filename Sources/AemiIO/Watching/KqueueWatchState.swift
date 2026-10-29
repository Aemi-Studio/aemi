#if canImport(Darwin)
    import Darwin

    /// What one ``KqueueWatcher`` watches, and the descriptors it holds open for it. Every call runs under the watcher's
    /// lock; the registrations it makes are plain `kevent` calls, which a thread blocked in the same queue tolerates.
    struct KqueueWatchState {
        /// A directory held open: asked for by the caller, or the anchor of watched files, or both.
        struct Directory {
            var tag: UInt
            var descriptor: Int32
            /// The caller watches it, so its changes are reported as directory changes.
            var explicit = false
            /// The watched files anchored on it: their parent, or their nearest existing ancestor.
            var files: Set<String> = []
        }

        /// A watched file, followed by its path.
        struct File {
            /// Its canonical paths, the keys suppression is recorded under.
            var keys: [String]
            /// Where it sits, symlinks above it resolved: the last of `keys`.
            var location: String
            /// The directory whose changes make it look again; "" before the first anchoring.
            var anchor = ""
            /// The descriptor open on whatever file is at the path, and which file that was.
            var tag: UInt?
            var descriptor: Int32?
            var opened: FileIdentity?
            /// What the path named at the last look; nil when nothing was there.
            var identity: FileIdentity?
        }

        enum Target {
            case directory(String)
            case file(String)
        }

        private var nextTag = KernelQueue.wakeTag + 1
        private var targets: [UInt: Target] = [:]
        private(set) var directories: [String: Directory] = [:]
        private(set) var files: [String: File] = [:]
        var isStopped = false

        /// Reports later changes to the entries of canonical `directory`.
        mutating func watchDirectory(_ directory: String, queue: KernelQueue) {
            guard attach(directory, queue: queue) else { return }
            directories[directory]?.explicit = true
        }

        /// Follows the file at `registered`, from what is there now.
        mutating func watchFile(_ registered: String, queue: KernelQueue) {
            guard files[registered] == nil else { return }
            let keys = CanonicalPath.keys(forFile: registered)
            files[registered] = File(keys: keys, location: keys[keys.count - 1])
            _ = look(at: registered, queue: queue)
        }

        mutating func unwatchFile(_ registered: String) {
            guard let file = files.removeValue(forKey: registered) else { return }
            closeDescriptor(of: file)
            directories[file.anchor]?.files.remove(registered)
            detachIfUnused(file.anchor)
        }

        /// What one kernel event means: the changes to report, before suppression.
        mutating func handle(_ event: KernelQueue.Event, queue: KernelQueue) -> [FileWatchEvent] {
            switch targets[event.tag] {
                case nil:
                    // A descriptor closed after the kernel queued its event: its tag is never reused, so nothing else.
                    return []
                case .directory(let path):
                    guard let directory = directories[path] else { return [] }
                    var changes: [FileWatchEvent] = directory.explicit ? [.directoryChanged(path)] : []
                    if event.flags & KernelQueue.goneFlags != 0 { drop(path) }
                    for registered in directory.files.sorted() where look(at: registered, queue: queue) {
                        changes.append(.fileChanged(registered))
                    }
                    return changes
                case .file(let registered):
                    // A write keeps the inode and may keep size and time to the tick: report it whatever the look says.
                    let wrote = event.flags & ~KernelQueue.goneFlags != 0
                    let changed = look(at: registered, queue: queue)
                    return changed || wrote ? [.fileChanged(registered)] : []
            }
        }

        /// Everything watched, as the events that make a consumer look at all of it again.
        func everything() -> [FileWatchEvent] {
            files.keys.sorted().map(FileWatchEvent.fileChanged)
                + directories.filter(\.value.explicit).keys.sorted().map(FileWatchEvent.directoryChanged)
        }

        /// Whether `event` concerns only paths `isSuppressed` accepts.
        func isSuppressed(_ event: FileWatchEvent, by isSuppressed: (String) -> Bool) -> Bool {
            switch event {
                case .fileChanged(let registered):
                    (files[registered]?.keys ?? [registered]).contains(where: isSuppressed)
                case .directoryChanged(let path): isSuppressed(path)
            }
        }

        /// Closes every descriptor; the watcher is done.
        mutating func closeAll() {
            for file in files.values { closeDescriptor(of: file) }
            for directory in directories.values { close(directory.descriptor) }
            files = [:]
            directories = [:]
            targets = [:]
        }

        /// Looks at the file again: anchors it on the deepest directory that exists above it, opens whatever file now
        /// sits at its path, and compares.
        /// - Returns: whether the path names something other than at the last look.
        private mutating func look(at registered: String, queue: KernelQueue) -> Bool {
            reanchor(registered, queue: queue)
            let now = FileIdentity(path: registered)
            reopen(registered, now: now, queue: queue)
            guard let previous = files[registered] else { return false }
            files[registered]?.identity = now
            return previous.identity != now
        }

        /// Moves the file onto the deepest directory that exists above it. A directory made between choosing an anchor
        /// and registering it raised no event there, so the choice is made again until it holds.
        private mutating func reanchor(_ registered: String, queue: KernelQueue) {
            while let file = files[registered] {
                let anchor = CanonicalPath.deepestExistingDirectory(above: file.location)
                guard anchor != file.anchor, attach(anchor, queue: queue) else { return }
                directories[anchor]?.files.insert(registered)
                files[registered]?.anchor = anchor
                directories[file.anchor]?.files.remove(registered)
                detachIfUnused(file.anchor)
            }
        }

        private mutating func reopen(_ registered: String, now: FileIdentity?, queue: KernelQueue) {
            guard let file = files[registered] else { return }
            if let now, let opened = file.opened, now.isSameFile(as: opened) { return }
            closeDescriptor(of: file)
            files[registered]?.tag = nil
            files[registered]?.descriptor = nil
            files[registered]?.opened = nil
            guard let now else { return }
            let tag = takeTag()
            guard let descriptor = queue.register(path: registered, notes: KernelQueue.fileFlags, tag: tag) else {
                return
            }
            targets[tag] = .file(registered)
            files[registered]?.tag = tag
            files[registered]?.descriptor = descriptor
            files[registered]?.opened = now
        }

        private mutating func attach(_ directory: String, queue: KernelQueue) -> Bool {
            if directories[directory] != nil { return true }
            let tag = takeTag()
            guard let descriptor = queue.register(path: directory, notes: KernelQueue.directoryFlags, tag: tag) else {
                return false
            }
            directories[directory] = Directory(tag: tag, descriptor: descriptor)
            targets[tag] = .directory(directory)
            return true
        }

        /// Closes a directory that went away. Its files find a new anchor on their next look; a directory the caller
        /// watched is no longer watched.
        private mutating func drop(_ directory: String) {
            guard let removed = directories.removeValue(forKey: directory) else { return }
            close(removed.descriptor)
            targets[removed.tag] = nil
            for registered in removed.files { files[registered]?.anchor = "" }
        }

        private mutating func detachIfUnused(_ directory: String) {
            guard let held = directories[directory], !held.explicit, held.files.isEmpty else { return }
            drop(directory)
        }

        private mutating func closeDescriptor(of file: File) {
            if let descriptor = file.descriptor { close(descriptor) }
            if let tag = file.tag { targets[tag] = nil }
        }

        private mutating func takeTag() -> UInt {
            defer { nextTag += 1 }
            return nextTag
        }
    }
#endif

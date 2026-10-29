#if canImport(Darwin)
    import Darwin

    /// One kqueue: vnode registrations each tagged with a caller's number, and a user event that wakes a blocked
    /// ``wait(into:)``. Registration and the wake may come from any thread while another waits; closing is the waiter's
    /// alone, after its last wait. The layer under ``DirectoryWatch`` and ``KqueueWatcher``.
    struct KernelQueue: Sendable {
        /// The tag of the wake event; vnode tags must differ from it.
        static let wakeTag: UInt = 1
        /// What a directory reports: entries added, removed or renamed, and the directory itself going away.
        static let directoryFlags = UInt32(
            NOTE_WRITE | NOTE_DELETE | NOTE_RENAME | NOTE_LINK | NOTE_ATTRIB | NOTE_REVOKE)
        /// What a file reports: writes and growth, metadata, and the file being removed, renamed or revoked.
        static let fileFlags = UInt32(
            NOTE_WRITE | NOTE_EXTEND | NOTE_ATTRIB | NOTE_DELETE | NOTE_RENAME | NOTE_LINK | NOTE_REVOKE)
        /// The flags that say the watched vnode no longer sits at its path.
        static let goneFlags = UInt32(NOTE_DELETE | NOTE_RENAME | NOTE_REVOKE)

        /// One delivered event: the tag it was registered with, and the `NOTE_` flags that fired.
        struct Event: Sendable {
            var tag: UInt
            var flags: UInt32
        }

        let descriptor: Int32

        /// A new kqueue with its wake event registered; nil when the system refuses either.
        init?() {
            let descriptor = kqueue()
            guard descriptor >= 0 else { return nil }
            var wake = unsafe Self.change(
                ident: 0, filter: EVFILT_USER, flags: EV_ADD | EV_CLEAR, notes: 0, tag: Self.wakeTag)
            guard unsafe kevent(descriptor, &wake, 1, nil, 0, nil) == 0 else {
                Darwin.close(descriptor)
                return nil
            }
            self.descriptor = descriptor
        }

        /// Opens `path` for events only and registers it under `tag`.
        /// - Returns: the opened descriptor, which the caller closes (closing it also removes the registration), or nil
        ///   when the path cannot be opened or registered.
        func register(path: String, notes: UInt32, tag: UInt) -> Int32? {
            let file = unsafe open(path, O_EVTONLY | O_CLOEXEC)
            guard file >= 0 else { return nil }
            var change = unsafe Self.change(
                ident: UInt(file), filter: EVFILT_VNODE, flags: EV_ADD | EV_CLEAR, notes: notes, tag: tag)
            guard unsafe kevent(descriptor, &change, 1, nil, 0, nil) == 0 else {
                Darwin.close(file)
                return nil
            }
            return file
        }

        /// Ends a blocked ``wait(into:)`` with a wake event. Never after ``close()``: the number may be reused by then.
        func wake() {
            // A change replaces the event's `udata`, so the trigger carries the wake tag again.
            var trigger = unsafe Self.change(
                ident: 0, filter: EVFILT_USER, flags: 0, notes: UInt32(NOTE_TRIGGER), tag: Self.wakeTag)
            _ = unsafe kevent(descriptor, &trigger, 1, nil, 0, nil)
        }

        /// Blocks until at least one event arrives, and returns up to `limit` of them; empty when the queue failed.
        /// Interrupted waits resume.
        func wait(limit: Int = 16) -> [Event] {
            var raw = unsafe Array(repeating: kevent(), count: limit)
            while true {
                let count = unsafe kevent(descriptor, nil, 0, &raw, Int32(limit), nil)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return [] }
                return unsafe raw.prefix(Int(count))
                    .map { event in
                        unsafe event.filter == Int16(EVFILT_USER)
                            ? Event(tag: Self.wakeTag, flags: 0)
                            : unsafe Event(tag: UInt(bitPattern: event.udata), flags: event.fflags)
                    }
            }
        }

        /// Closes the queue. - Returns: whether `close` succeeded, which means it was open and is closed exactly once.
        @discardableResult
        func close() -> Bool {
            Darwin.close(descriptor) == 0
        }

        private static func change(ident: UInt, filter: Int32, flags: Int32, notes: UInt32, tag: UInt) -> kevent {
            unsafe kevent(
                ident: ident, filter: Int16(filter), flags: UInt16(flags), fflags: notes, data: 0,
                udata: UnsafeMutableRawPointer(bitPattern: tag))
        }
    }
#endif

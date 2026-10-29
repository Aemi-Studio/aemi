#if os(macOS)
    import CoreServices
    import Dispatch

    /// The FSEvents stream of one ``FileWatcher``, and the serial queue it calls back on.
    ///
    /// Memory safety rests on two rules. FSEvents owns this controller through the context's `retain` and `release`
    /// callbacks, so `info` stays valid for as long as a stream exists, however late a callback runs. And every operation
    /// on a stream, creation, restart and teardown included, runs on `queue`, so none can interleave with a callback in
    /// flight. The queue is required: FSEvents' only non-deprecated scheduling API takes one.
    @safe final class FSEventStreamController: @unchecked Sendable {
        // Invariant: every `var` is read and written only on `queue`.
        private let queue = DispatchQueue(label: "AemiIO.FileWatcher.events", qos: .utility)
        private let latency: Double
        private let continuation: AsyncStream<FileWatchEvent>.Continuation
        private let suppression: SuppressionWindow
        private let epoch: ContinuousClock.Instant
        private let onFailure: @Sendable (String) -> Void
        private var table = WatchTable()
        private var stream: FSEventStreamRef?
        /// The paths and exclusions `stream` was created with; empty while none runs.
        private var streamRoots: [String] = []
        private var streamExclusions: [String] = []
        private var isInvalidated = false

        init(
            latency: Double, continuation: AsyncStream<FileWatchEvent>.Continuation, suppression: SuppressionWindow,
            epoch: ContinuousClock.Instant, onFailure: @escaping @Sendable (String) -> Void
        ) {
            self.latency = latency
            self.continuation = continuation
            self.suppression = suppression
            self.epoch = epoch
            self.onFailure = onFailure
        }

        /// Routes later events through `table`, restarting the stream when its paths or exclusions changed.
        /// - Parameters:
        ///   - table: What the watcher now watches.
        ///   - requestedAt: The system's event ID when the caller asked.
        func apply(_ table: WatchTable, requestedAt: FSEventStreamEventId) {
            queue.async { [self] in
                guard !isInvalidated else { return }
                self.table = table
                let roots = table.roots
                guard roots != streamRoots || table.exclusions != streamExclusions else { return }
                restart(over: roots, requestedAt: requestedAt)
            }
        }

        /// Tears the stream down for good; later ``apply(_:requestedAt:)`` calls do nothing.
        func invalidate() {
            queue.async { [self] in
                isInvalidated = true
                _ = tearDown()
            }
        }

        /// Returns once every block queued before it has run.
        func synchronize() async {
            await withCheckedContinuation { continuation in
                queue.async { continuation.resume() }
            }
        }

        /// Replaces the running stream with one over `roots`. The new stream replays history from the older of
        /// `requestedAt` and the last event the old one delivered, so nothing either would have reported is lost; what
        /// it replays from before a watch began, ``WatchTable/isStale(_:id:)`` drops, and what it replays twice,
        /// consumers already take as a repeated change.
        private func restart(over roots: [String], requestedAt: FSEventStreamEventId) {
            let latest = tearDown()
            guard !roots.isEmpty else { return }
            guard let stream = unsafe makeStream(over: roots, since: min(latest ?? requestedAt, requestedAt)) else {
                onFailure("FSEvents refused a stream over \(roots.count) directories")
                return
            }
            let excluded =
                unsafe table.exclusions.isEmpty
                || FSEventStreamSetExclusionPaths(stream, Self.stringArray(table.exclusions))
            if !excluded {
                onFailure("FSEvents refused \(table.exclusions.count) exclusion paths")
            }
            unsafe FSEventStreamSetDispatchQueue(stream, queue)
            guard unsafe FSEventStreamStart(stream) else {
                onFailure("FSEvents could not start a stream over \(roots.count) directories")
                unsafe FSEventStreamInvalidate(stream)
                unsafe FSEventStreamRelease(stream)
                return
            }
            unsafe self.stream = stream
            streamRoots = roots
            streamExclusions = table.exclusions
        }

        /// Stops and releases the running stream.
        /// - Returns: The last event ID it delivered, or nil when no stream ran.
        private func tearDown() -> FSEventStreamEventId? {
            guard let stream = unsafe stream else { return nil }
            unsafe FSEventStreamStop(stream)
            let latest = unsafe FSEventStreamGetLatestEventId(stream)
            unsafe FSEventStreamInvalidate(stream)
            unsafe FSEventStreamRelease(stream)
            unsafe self.stream = nil
            streamRoots = []
            streamExclusions = []
            return latest
        }

        private func makeStream(over roots: [String], since: FSEventStreamEventId) -> FSEventStreamRef? {
            var context = unsafe FSEventStreamContext(
                version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                retain: { info in
                    guard let info = unsafe info else { return nil }
                    _ = unsafe Unmanaged<FSEventStreamController>.fromOpaque(info).retain()
                    return unsafe info
                },
                release: { info in
                    guard let info = unsafe info else { return }
                    unsafe Unmanaged<FSEventStreamController>.fromOpaque(info).release()
                },
                copyDescription: nil)
            return unsafe FSEventStreamCreate(
                nil,
                { _, info, count, eventPaths, eventFlags, eventIds in
                    guard let info = unsafe info else { return }
                    // Without `UseCFTypes`, the paths are a C array of C strings. FSEvents lends them, the flags and the
                    // IDs for the duration of this call only; they are copied before it returns.
                    let cPaths = unsafe eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
                    let paths = (0 ..< count).map { unsafe String(cString: cPaths[$0]) }
                    let flags = unsafe Array(UnsafeBufferPointer(start: eventFlags, count: count))
                    let ids = unsafe Array(UnsafeBufferPointer(start: eventIds, count: count))
                    unsafe Unmanaged<FSEventStreamController>.fromOpaque(info).takeUnretainedValue()
                        .receive(paths: paths, flags: flags, ids: ids)
                },
                &context,
                Self.stringArray(roots),
                since,
                latency,
                FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
            )
        }

        /// A `CFArray` of `CFString`s, built without Foundation's bridging.
        private static func stringArray(_ strings: [String]) -> CFArray {
            let values = strings.compactMap { string in
                unsafe CFStringCreateWithCString(kCFAllocatorDefault, string, CFStringBuiltInEncodings.UTF8.rawValue)
            }
            var pointers: [UnsafeRawPointer?] = unsafe values.map {
                unsafe UnsafeRawPointer(Unmanaged.passUnretained($0).toOpaque())
            }
            return withUnsafePointer(to: kCFTypeArrayCallBacks) { callbacks in
                // The array retains each string through the callbacks; `values` keeps them alive until then.
                withExtendedLifetime(values) {
                    unsafe CFArrayCreate(kCFAllocatorDefault, &pointers, pointers.count, callbacks)
                }
            }
        }

        /// Routes one callback's events and yields them; runs on `queue`. When the buffer overflows, everything watched
        /// is reported once more at the end, the newest events and so the ones kept.
        private func receive(paths: [String], flags: [FSEventStreamEventFlags], ids: [FSEventStreamEventId]) {
            let now = epoch.duration(to: ContinuousClock.now)
            var overflowed = false
            func report(_ event: FileWatchEvent) {
                if case .dropped = continuation.yield(event) { overflowed = true }
            }
            for index in 0 ..< min(paths.count, flags.count, ids.count) {
                let route = table.route(
                    path: paths[index], flags: flags[index], id: ids[index],
                    isSuppressed: { suppression.isSuppressed($0, now: now) })
                switch route {
                    case .skip: continue
                    case .files(let registered): for path in registered { report(.fileChanged(path)) }
                    case .directory(let path): report(.directoryChanged(path))
                    case .rescan(let path): for event in table.rescanEvents(below: path) { report(event) }
                }
            }
            guard overflowed else { return }
            for event in table.rescanEvents(below: "/") {
                continuation.yield(event)
            }
        }
    }
#endif

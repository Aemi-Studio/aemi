internal import AemiIO

#if canImport(Darwin)
    internal import Darwin
#elseif canImport(Glibc)
    internal import Glibc
#endif

/// The walk itself: a shared queue of root-relative directory paths, worked by a bounded pool of threads, each listing one
/// directory completely with `readdir` (ADR 0017).
final class WalkEngine: @unchecked Sendable {
    private let root: String
    private let rootDescriptor: Int32
    /// The root's real path and that path followed by `/`, for deciding whether a link resolves inside it.
    private let realRoot: String
    private let policy: DirectoryWalk.Policy
    private let afterListing: (@Sendable (String) -> Void)?
    private let onBatch: (@Sendable ([DirectoryWalk.Entry]) -> Void)?

    // Everything below is guarded by `monitor`.
    private let monitor = Monitor()
    private var queue: [String] = [""]
    private var busy = 0
    private var finishedWorkers = 0
    private var entries: [DirectoryWalk.Entry] = []
    private var failures: [DirectoryWalk.Failure] = []
    private var statistics = DirectoryWalk.Statistics()
    private var openDescriptors = 1
    private var limited = false
    private var cancelled = false

    init(
        root: String, policy: DirectoryWalk.Policy, afterListing: (@Sendable (String) -> Void)?,
        onBatch: (@Sendable ([DirectoryWalk.Entry]) -> Void)?
    ) throws(IOError) {
        let descriptor = unsafe open(root, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw Self.failure("open \(root)") }
        self.root = root
        rootDescriptor = descriptor
        realRoot = Self.realPath(root) ?? root
        self.policy = policy
        self.afterListing = afterListing
        self.onBatch = onBatch
        statistics.peakOpenDescriptors = 1
    }

    deinit { close(rootDescriptor) }

    /// Runs the walk on `policy.workers` threads, this one included, and returns when every worker has finished.
    func run() -> DirectoryWalk.Result {
        var started = 1
        for _ in 1 ..< max(1, policy.workers) {
            guard WorkerThread.spawn({ [self] in work() }) else { break }
            started += 1
        }
        work()
        // Every worker started must leave `work()` before the state is read: none can touch it after this.
        monitor.lock()
        while finishedWorkers < started { monitor.wait() }
        let sorted = entries.sorted { $0.relativePath < $1.relativePath }
        let result = DirectoryWalk.Result(
            root: root, entries: sorted, failures: failures.sorted { $0.relativePath < $1.relativePath },
            limited: limited, cancelled: cancelled, statistics: statistics)
        monitor.unlock()
        return result
    }

    /// One worker: takes directories until the queue is empty and no other worker can add to it, or the walk stops.
    private func work() {
        while let directory = next() {
            let listing = list(directory)
            finish(directory, listing)
        }
        monitor.lock()
        finishedWorkers += 1
        monitor.broadcast()
        monitor.unlock()
    }

    private var stopped: Bool { limited || cancelled }

    private func next() -> String? {
        monitor.lock()
        defer { monitor.unlock() }
        while queue.isEmpty && busy > 0 && !stopped { monitor.wait() }
        guard !stopped, let directory = queue.popLast() else {
            monitor.broadcast()
            return nil
        }
        if let isCancelled = policy.isCancelled, isCancelled() {
            cancelled = true
            monitor.broadcast()
            return nil
        }
        busy += 1
        openDescriptors += 1
        statistics.peakOpenDescriptors = max(statistics.peakOpenDescriptors, openDescriptors)
        return directory
    }

    private struct Listing {
        var reported: [DirectoryWalk.Entry] = []
        var subdirectories: [String] = []
        var failure: IOError?
        var statCalls = 0
        var opened = false
    }

    /// Lists `directory` (relative to the root, "" for the root) completely, outside the lock.
    private func list(_ directory: String) -> Listing {
        var listing = Listing()
        guard let handle = unsafe openDirectory(directory, failure: &listing.failure) else { return listing }
        listing.opened = true
        let depth = directory.isEmpty ? 0 : directory.utf8.reduce(1) { $1 == UInt8(ascii: "/") ? $0 + 1 : $0 }
        defer { unsafe closedir(handle) }
        while let record = unsafe readdir(handle) {
            let name = unsafe Self.name(of: record)
            guard name != ".", name != "..", !policy.skippedNames.contains(name),
                policy.includesHidden || !name.hasPrefix(".")
            else { continue }
            let path = directory.isEmpty ? name : directory + "/" + name
            var kind = Self.kind(of: unsafe record.pointee.d_type)
            if kind == nil {
                listing.statCalls += 1
                var status = stat()
                kind =
                    unsafe fstatat(rootDescriptor, path, &status, AT_SYMLINK_NOFOLLOW) == 0
                    ? Self.kind(of: status.st_mode) : .other
            }
            guard var kind else { continue }
            if kind == .link, policy.links == .withinRoot {
                // A link into the root stands for its target, which the walk reaches at its own path.
                if let target = Self.realPath(root + "/" + path), target == realRoot || target.hasPrefix(realRoot + "/")
                {
                    continue
                }
                kind = .link
            }
            let candidate = DirectoryWalk.Candidate(relativePath: path, name: name, kind: kind)
            if let accepts = policy.accepts, !accepts(candidate) { continue }
            if kind == .directory {
                // A directory at the last level asked for is reported, not entered.
                if Self.enters(depth: depth + 1, within: policy.maxDepth) { listing.subdirectories.append(path) }
                if policy.reportsDirectories { listing.reported.append(.init(relativePath: path, kind: .directory)) }
            } else {
                listing.reported.append(.init(relativePath: path, kind: kind))
            }
        }
        listing.reported.sort { $0.relativePath < $1.relativePath }
        afterListing?(directory)
        return listing
    }

    /// Records a listing: its entries (up to the limit), its failure, its subdirectories for later.
    private func finish(_ directory: String, _ listing: Listing) {
        monitor.lock()
        defer {
            monitor.broadcast()
            monitor.unlock()
        }
        busy -= 1
        openDescriptors -= 1
        statistics.statCalls += listing.statCalls
        if listing.opened { statistics.directoriesOpened += 1 }
        if let error = listing.failure {
            failures.append(DirectoryWalk.Failure(relativePath: directory, error: error))
        }
        var reported = listing.reported
        if let limit = policy.limit, entries.count + reported.count >= limit {
            reported = Array(reported.prefix(max(0, limit - entries.count)))
            limited = true
        }
        entries += reported
        if !reported.isEmpty { onBatch?(reported) }
        if !stopped { queue += listing.subdirectories.reversed() }
    }

    /// `directory` opened relative to the root with no link followed anywhere on its path.
    private func openDirectory(_ directory: String, failure: inout IOError?) -> UnsafeMutablePointer<DIR>? {
        let path = directory.isEmpty ? "." : directory
        #if canImport(Darwin)
            let descriptor = unsafe openat(rootDescriptor, path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        #else
            let descriptor = Self.openWithoutLinks(rootDescriptor, path)
        #endif
        guard descriptor >= 0 else {
            failure = Self.failure("openat \(path)")
            return nil
        }
        guard let handle = unsafe fdopendir(descriptor) else {
            failure = Self.failure("fdopendir \(path)")
            close(descriptor)
            return nil
        }
        return unsafe handle
    }

    #if !canImport(Darwin)
        /// Linux has no `O_NOFOLLOW_ANY`: each component is opened from its parent with `O_NOFOLLOW`.
        private static func openWithoutLinks(_ root: Int32, _ path: String) -> Int32 {
            var current = dup(root)
            guard current >= 0 else { return -1 }
            for component in path.split(separator: "/") where component != "." {
                let next = openat(current, String(component), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                close(current)
                guard next >= 0 else { return -1 }
                current = next
            }
            return current
        }
    #endif

    /// Whether a directory `depth` levels below the root (its entries one level deeper) is listed under `maxDepth`.
    private static func enters(depth: Int, within maxDepth: Int?) -> Bool { maxDepth.map { depth < $0 } ?? true }

    private static func name(of record: UnsafeMutablePointer<dirent>) -> String {
        unsafe withUnsafePointer(to: &record.pointee.d_name) { tuple in
            unsafe tuple.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: tuple.pointee)) {
                unsafe String(cString: $0)
            }
        }
    }

    private static func kind(of type: UInt8) -> DirectoryWalk.Kind? {
        switch Int32(type) {
            case DT_DIR: .directory
            case DT_REG: .file
            case DT_LNK: .link
            case DT_UNKNOWN: nil
            default: .other
        }
    }

    private static func kind(of mode: mode_t) -> DirectoryWalk.Kind {
        switch mode & S_IFMT {
            case S_IFDIR: .directory
            case S_IFREG: .file
            case S_IFLNK: .link
            default: .other
        }
    }

    /// An ``IOError`` with the current `errno`, read before the label is built (building it may allocate and change
    /// `errno`).
    static func failure(_ operation: @autoclosure () -> String) -> IOError {
        #if canImport(Darwin)
            let code = Darwin.errno
        #else
            let code = Glibc.errno
        #endif
        return IOError(errno: code, op: operation())
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = unsafe realpath(path, nil) else { return nil }
        defer { unsafe free(resolved) }
        return unsafe String(cString: resolved)
    }
}

/// A pthread mutex and condition variable; the pointers never leave it.
@safe final class Monitor: @unchecked Sendable {
    private let mutex = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
    private let condition = UnsafeMutablePointer<pthread_cond_t>.allocate(capacity: 1)

    init() {
        unsafe pthread_mutex_init(mutex, nil)
        unsafe pthread_cond_init(condition, nil)
    }

    deinit {
        unsafe pthread_cond_destroy(condition)
        unsafe pthread_mutex_destroy(mutex)
        unsafe condition.deallocate()
        unsafe mutex.deallocate()
    }

    func lock() { unsafe pthread_mutex_lock(mutex) }
    func unlock() { unsafe pthread_mutex_unlock(mutex) }
    func wait() { unsafe pthread_cond_wait(condition, mutex) }
    func broadcast() { unsafe pthread_cond_broadcast(condition) }
}

/// Detached POSIX threads, for the walk's workers.
enum WorkerThread {
    private final class Job: Sendable {
        let work: @Sendable () -> Void
        init(_ work: @escaping @Sendable () -> Void) { self.work = work }
    }

    /// Starts `work` on a new detached thread; false when none could be created (the caller does the work itself).
    static func spawn(_ work: @escaping @Sendable () -> Void) -> Bool {
        var attributes = pthread_attr_t()
        guard unsafe pthread_attr_init(&attributes) == 0 else { return false }
        defer { unsafe pthread_attr_destroy(&attributes) }
        guard unsafe pthread_attr_setdetachstate(&attributes, Int32(PTHREAD_CREATE_DETACHED)) == 0 else { return false }
        let context = unsafe Unmanaged.passRetained(Job(work)).toOpaque()
        #if canImport(Darwin)
            var thread: pthread_t?
            let status = unsafe pthread_create(&thread, &attributes, { unsafe WorkerThread.start($0) }, context)
        #else
            var thread = pthread_t()
            let status = unsafe pthread_create(
                &thread, &attributes,
                { context in
                    guard let context = unsafe context else { return nil }
                    return unsafe WorkerThread.start(context)
                }, context)
        #endif
        if status != 0 {
            unsafe Unmanaged<Job>.fromOpaque(context).release()
            return false
        }
        return true
    }

    private static func start(_ context: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? {
        unsafe Unmanaged<Job>.fromOpaque(context).takeRetainedValue().work()
        return nil
    }
}

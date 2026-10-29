public import AemiIO

/// A parallel walk of a directory tree that reads entry types from directory records, not inodes (ADR 0017).
///
/// Every directory is opened relative to the root without following any link on its path, so a directory replaced by a
/// link while the walk runs is refused, not followed; the queue holds relative paths, so the walk keeps one descriptor
/// per worker open, plus the root, whatever the tree's width.
public enum DirectoryWalk {
    /// What an entry is, from its directory record (or, for an unknown type, one `fstatat`).
    public enum Kind: Sendable, Hashable {
        case file
        case directory
        /// A link the policy does not follow, or one whose target does not resolve inside the root.
        case link
        case other
    }

    /// How links are treated.
    public enum Links: Sendable, Hashable {
        /// Reported as ``Kind/link``, never followed.
        case never
        /// A link whose target resolves inside the root stands for that target, which the walk reaches at its own
        /// path: the link itself is not reported. A link out of the root, or one that does not resolve, is reported as
        /// ``Kind/link``. No link is ever descended, so a cycle cannot loop and the result does not depend on which
        /// spelling a worker reached first.
        case withinRoot
    }

    /// An entry the walk is about to report or enter, for the policy's predicate.
    public struct Candidate: Sendable {
        /// The path relative to the root, `/`-separated.
        public let relativePath: String
        public let name: String
        public let kind: Kind
    }

    public struct Policy: Sendable {
        /// Names never reported or entered (`.build`, `.git`, …).
        public var skippedNames: Set<String>
        /// Whether entries whose name starts with `.` are reported and entered.
        public var includesHidden: Bool
        public var links: Links
        /// Asked about every entry that survives the names: a directory refused is not entered, any other entry
        /// refused is not reported. Nil keeps everything.
        public var accepts: (@Sendable (Candidate) -> Bool)?
        /// Whether directories are themselves reported as entries.
        public var reportsDirectories: Bool
        /// Stop after this many entries; the result says it was limited.
        public var limit: Int?
        /// How many levels are listed: 1 lists the root's entries and enters none of its directories. Directories at the
        /// last level are still reported when ``reportsDirectories`` asks for them. Nil walks the whole tree.
        public var maxDepth: Int?
        /// Worker threads; four was the measured knee (diary 2026-10-29-02).
        public var workers: Int
        /// Polled between directories; true stops the walk, and the result says it was cancelled.
        public var isCancelled: (@Sendable () -> Bool)?

        public init(
            skippedNames: Set<String> = [], includesHidden: Bool = false, links: Links = .never,
            accepts: (@Sendable (Candidate) -> Bool)? = nil, reportsDirectories: Bool = false, limit: Int? = nil,
            maxDepth: Int? = nil, workers: Int = 4, isCancelled: (@Sendable () -> Bool)? = nil
        ) {
            self.skippedNames = skippedNames
            self.includesHidden = includesHidden
            self.links = links
            self.accepts = accepts
            self.reportsDirectories = reportsDirectories
            self.limit = limit
            self.maxDepth = maxDepth
            self.workers = workers
            self.isCancelled = isCancelled
        }
    }

    public struct Entry: Sendable, Hashable {
        /// Relative to the root, `/`-separated.
        public let relativePath: String
        public let kind: Kind

        public init(relativePath: String, kind: Kind) {
            self.relativePath = relativePath
            self.kind = kind
        }
    }

    /// A directory that could not be opened or read.
    public struct Failure: Sendable, Equatable {
        public let relativePath: String
        public let error: IOError
    }

    /// What the walk cost, for tests and measurements.
    public struct Statistics: Sendable, Equatable {
        /// `fstatat` calls: only for unknown types, links to resolve and directory identities.
        public var statCalls = 0
        public var directoriesOpened = 0
        /// The most descriptors the walk held open at once, the root included.
        public var peakOpenDescriptors = 0
    }

    public struct Result: Sendable {
        /// The root as given; the relative paths hang from it.
        public let root: String
        /// Sorted by relative path.
        public let entries: [Entry]
        public let failures: [Failure]
        public let limited: Bool
        public let cancelled: Bool
        public let statistics: Statistics
    }

    /// Walks `root` under `policy`.
    /// - Throws: an ``IOError`` when the root itself cannot be opened.
    public static func walk(_ root: String, policy: Policy = Policy()) throws(IOError) -> Result {
        try walk(root, policy: policy, afterListing: nil)
    }

    /// The test seam for a tree changing under the walk: called after a directory is listed and before any of its
    /// subdirectories is opened.
    static func walk(_ root: String, policy: Policy, afterListing: (@Sendable (String) -> Void)?) throws(IOError)
        -> Result
    {
        try WalkEngine(root: root, policy: policy, afterListing: afterListing, onBatch: nil).run()
    }

    /// The same walk as batches of entries, each sorted, delivered while the walk runs; the stream finishes after the
    /// last batch, or with the root's ``IOError``.
    public static func batches(_ root: String, policy: Policy = Policy()) -> AsyncThrowingStream<[Entry], any Error> {
        AsyncThrowingStream { continuation in
            // A consumer that stops listening cancels the walk.
            let stopped = Flag()
            continuation.onTermination = { _ in stopped.set() }
            var streamed = policy
            let asked = policy.isCancelled
            streamed.isCancelled = { stopped.isSet || asked?() == true }
            let engine: WalkEngine
            do {
                engine = try WalkEngine(
                    root: root, policy: streamed, afterListing: nil, onBatch: { continuation.yield($0) })
            } catch {
                continuation.finish(throwing: error)
                return
            }
            let run: @Sendable () -> Void = {
                _ = engine.run()
                continuation.finish()
            }
            if !WorkerThread.spawn(run) { run() }
        }
    }

    /// A flag set once, from any thread.
    private final class Flag: @unchecked Sendable {
        private let monitor = Monitor()
        private var value = false

        var isSet: Bool {
            monitor.lock()
            defer { monitor.unlock() }
            return value
        }

        func set() {
            monitor.lock()
            value = true
            monitor.unlock()
        }
    }
}

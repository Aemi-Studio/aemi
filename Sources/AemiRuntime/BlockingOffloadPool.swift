import Dispatch
public import Foundation  // Thread; QualityOfService appears in the public init signature
private import Synchronization

/// A bounded pool of dedicated OS threads that run BLOCKING work off Swift's cooperative thread
/// pool, bridging each result back to `async`.
///
/// ## Why this exists
/// Some library calls are synchronous AND blocking — they park the calling thread (a B-tree walk
/// that faults `mmap` pages, a `read(2)`, a `writeSync`). Running one directly from an `async`
/// context blocks a cooperative-pool thread, and that pool has only ~`processorCount` threads, so
/// a handful of concurrent blocking calls can starve every UNRELATED task in the process — a
/// forward-progress violation. This pool moves each blocking call onto one of `width` dedicated
/// threads it owns, so the cooperative pool keeps running.
///
/// ## Correctness
/// The wakeup is a counting `DispatchSemaphore` signalled exactly once per enqueue and waited
/// exactly once per popped job — one-to-one accounting that is **lost-wakeup-free** regardless of
/// enqueue/drain interleaving (the mistake a hand-rolled condition variable invites). `shutdown()`
/// **joins** every worker (each signals an exit semaphore) before returning, so the owner can
/// release the pool with no thread still touching it. The `run` queue is bounded (`maxDepth`), so a
/// producer faster than the pool drains cannot grow memory without limit — the `TaskExecutor.enqueue`
/// path is *necessarily* exempt from that bound (the runtime cannot be back-pressured through a
/// scheduling callback without stranding the job); see ``enqueue(_:)``.
///
/// ## Use
/// `await pool.run { blockingCall() }` runs the closure on a pool thread and suspends the caller
/// until it returns (or throws). Cancelling the awaiting task BEFORE its job starts removes the job
/// and throws `CancellationError` — a job already running cannot be interrupted, the blocking call
/// must finish. The pool also conforms to `TaskExecutor`, so
/// `await withTaskExecutorPreference(pool) { blockingCall() }` is an alternative that keeps the
/// `width` concurrency bound while integrating natively with structured-concurrency cancellation.
///
/// Generalizes the single-thread `ADDBCore.WriterThread` (same 1:1-semaphore + real-join
/// discipline) to `width` threads, so an async database façade can offload its blocking reads
/// without hand-rolling — and getting wrong — a thread pool. The owner MUST call `shutdown()`
/// (e.g. from its `close()` / `deinit`): the worker threads keep the pool alive until then.
public final class BlockingOffloadPool: Sendable {
    /// Why a `run` submission was refused.
    public enum SubmissionError: Error, Sendable {
        /// `shutdown()` has been called; the pool no longer accepts work.
        case poolShuttingDown
        /// The queue already holds `maxDepth` jobs; the caller should shed load / back off.
        case queueFull(maxDepth: Int)
    }

    /// One unit of work. `@unchecked Sendable`: `work`/`cancel` capture a `CheckedContinuation`
    /// (itself `Sendable`) plus the caller's `@Sendable` body, and the job is handed to exactly one
    /// worker (or, for the cancel path, removed under the lock before the worker can take it), so it
    /// never runs concurrently with itself. Same discipline as `WriterThread.Job`.
    private struct Job: @unchecked Sendable {
        let id: UInt64
        let work: () -> Void  // run the unit of work (body+resume, or an ExecutorJob)
        let cancel: (() -> Void)?  // resume the continuation with CancellationError (run<T> path only)
    }
    private struct State {
        var queue: [Job] = []
        var stopping = false
        var nextID: UInt64 = 0
    }

    private let state = Mutex(State())
    /// Counting wakeup: signalled 1:1 per accepted enqueue and per stop-wake; waited once per loop
    /// turn. One-to-one accounting is what makes wakeups lost-wakeup-free (cf. `WriterThread`).
    private let wakeup = DispatchSemaphore(value: 0)
    /// A worker signals this exactly once as it exits, so `shutdown` can join all `width` of them.
    private let exited = DispatchSemaphore(value: 0)
    private let didShutdown = Atomic<Bool>(false)
    private let width: Int
    private let maxDepth: Int

    /// Create a pool of `width` dedicated worker threads (floored at 1).
    /// - Parameters:
    ///   - width: worker-thread count = the maximum number of concurrent blocking calls.
    ///   - maxDepth: `run` queue cap; submissions beyond it throw `SubmissionError.queueFull`.
    ///   - qualityOfService: scheduling class for the worker threads. Blocking work a caller is
    ///     awaiting wants `.userInitiated` (the default, matching `WriterThread`); a background
    ///     consumer can lower it.
    public init(width: Int, maxDepth: Int = 1024, qualityOfService: QualityOfService = .userInitiated) {
        self.width = max(1, width)
        self.maxDepth = max(1, maxDepth)
        for index in 0 ..< self.width {
            let thread = Thread { [weak self] in self?.runLoop() }
            thread.name = "BlockingOffloadPool-\(index)"
            thread.qualityOfService = qualityOfService
            thread.start()
        }
    }

    /// Run `body` on a pool thread; suspend the caller until it returns or throws. Cancelling the
    /// awaiting task before the job starts removes it from the queue and throws `CancellationError`;
    /// a task ALREADY cancelled when `run` is entered is likewise honored (its `body` never runs).
    public func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        let id = nextJobID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                // Already-cancelled-on-entry: `withTaskCancellationHandler` fires `onCancel` before this
                // closure runs, but the job is not in the queue yet, so `onCancel` removed nothing.
                // Honor the cancellation here instead of running `body`. Because we return WITHOUT
                // admitting, the job never enters the queue, so `onCancel` can never find it either —
                // this branch owns the (single) resume with no race against the removal path.
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let job = Job(
                    id: id,
                    work: { continuation.resume(with: Result { try body() }) },
                    cancel: { continuation.resume(throwing: CancellationError()) })
                if let error = admit(job) {
                    continuation.resume(throwing: error)
                } else {
                    wakeup.signal()
                }
            }
        } onCancel: {
            // Whoever removes the job from the queue under the lock owns resuming it exactly once;
            // if a worker already took it, `firstIndex` finds nothing and the running job resumes.
            let job: Job? = state.withLock { state in
                guard let index = state.queue.firstIndex(where: { $0.id == id }) else { return nil }
                return state.queue.remove(at: index)
            }
            job?.cancel?()
        }
    }

    private func nextJobID() -> UInt64 {
        state.withLock { state in
            let id = state.nextID
            state.nextID &+= 1
            return id
        }
    }

    /// Append `job` for a worker to run, or return the reason it was refused (`nil` == accepted).
    private func admit(_ job: Job) -> SubmissionError? {
        state.withLock { state in
            guard !state.stopping else { return .poolShuttingDown }
            guard state.queue.count < maxDepth else { return .queueFull(maxDepth: maxDepth) }
            state.queue.append(job)
            return nil
        }
    }

    private func runLoop() {
        while true {
            wakeup.wait()
            let job: Job? = state.withLock { $0.queue.isEmpty ? nil : $0.queue.removeFirst() }
            if let job {
                job.work()
            } else if state.withLock({ $0.stopping }) {
                exited.signal()
                return
            }
        }
    }

    /// Stop accepting work, drain already-queued jobs, and JOIN every worker before returning.
    /// Idempotent — only the first call performs the shutdown; later calls return immediately.
    public func shutdown() {
        guard didShutdown.exchange(true, ordering: .acquiringAndReleasing) == false else { return }
        state.withLock { $0.stopping = true }
        for _ in 0 ..< width { wakeup.signal() }  // wake every worker so it observes `stopping`
        for _ in 0 ..< width { exited.wait() }  // join: await every worker's exit
    }
}

extension BlockingOffloadPool: TaskExecutor {
    /// `TaskExecutor` requirement: run a runtime job on a pool thread, so async work under
    /// `withTaskExecutorPreference(self)` executes here (width-bounded) instead of the cooperative
    /// pool.
    ///
    /// ## Why this path does NOT enforce `maxDepth`
    /// Unlike ``run(_:)`` (whose caller `admit` can refuse with `SubmissionError.queueFull` and shed
    /// load), `enqueue` is the Swift runtime's fire-and-forget scheduling callback: the runtime has
    /// ALREADY committed this job to this executor and offers no way to signal back-pressure or
    /// refusal. Dropping or bouncing the job would STRAND the owning task forever (it would never
    /// resume) — a forward-progress violation far worse than an over-deep queue. So the only safe
    /// overflow policy here is to **accept unconditionally**; `maxDepth` is therefore a bound on the
    /// ``run(_:)`` submission API only, not on the executor path. This is not a leak in practice:
    /// the depth of this queue is bounded by the number of live tasks the caller has placed under
    /// `withTaskExecutorPreference(self)`, which the caller controls. Running the job inline when
    /// "full" is deliberately NOT done — that would execute blocking work on the enqueuing
    /// (cooperative-pool) thread, reintroducing the exact starvation this pool exists to prevent.
    ///
    /// The one inline-run case is shutdown: once `stopping`, no worker will drain new jobs, so running
    /// inline is the only way to keep the task making progress instead of hanging. Never drops a job.
    public func enqueue(_ job: consuming ExecutorJob) {
        let unowned = UnownedJob(job)
        let executor = asUnownedTaskExecutor()
        let queued = state.withLock { state -> Bool in
            // Deliberately no `maxDepth` guard here (see the doc above): the runtime cannot be
            // back-pressured through `enqueue`, so refusing a job would strand its task. Only
            // `stopping` gates acceptance, and that path still runs the job (inline, below).
            guard !state.stopping else { return false }
            let id = state.nextID
            state.nextID &+= 1
            state.queue.append(Job(id: id, work: { unowned.runSynchronously(on: executor) }, cancel: nil))
            return true
        }
        if queued {
            wakeup.signal()
        } else {
            unowned.runSynchronously(on: executor)  // pool stopping: run inline, never drop (no hang)
        }
    }
}

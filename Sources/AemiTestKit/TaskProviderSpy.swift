// `public import`: `TaskProviderSpy` is public and conforms to `TaskProvider`, which this module
// re-exports from the `AemiRuntime` leaf via `AemiTestKitSeams` (`@_exported import`). Under
// `InternalImportsByDefault` the re-exported protocol must be imported publicly to appear in this
// public conformance.
public import AemiTestKitSeams
import Synchronization
public import Testing

/// A `TaskProvider` for tests that spawns *real* tasks (so the work actually runs)
/// while tracking them, then settles them deterministically. A library that takes a
/// `TaskProvider` (defaulting to `LiveTaskProvider` in production) is handed this in a
/// test; instead of racing on serial-result comparison, the test triggers the work
/// and `await spy.waitForAllTasks()`.
///
/// ## Work and observations
///
/// `.work` tasks are the ones a test settles: the spy counts each spawn when `task` is called and each
/// completion when the task's body ends. ``waitForAllTasks(within:clock:)`` waits for all of them
/// *transitively* — for all-spawned-so-far to complete, then re-checks whether the wait itself spawned more —
/// until the spawn count stabilizes with everything complete.
///
/// `.observation` tasks (long-lived stream / observation loops that never finish on their own) are tracked
/// apart, so awaiting the work can never hang on them. They end when their input ends or when
/// ``cancelObservations()`` runs; ``waitForObservationsToFinish(within:clock:)`` waits for that.
///
/// ## Teardown
///
/// Both kinds keep a handle to their task so they can be cancelled deterministically:
/// ``cancelPendingWork()`` and ``cancelObservations()``. `deinit` calls both as a safety net, so a forgotten
/// teardown cannot leave a suspended task running on the shared test executor after the test.
///
/// ## Deadlines
///
/// Every wait races a clock-injectable deadline, so under a `TestClock` settling is real-time-free, and a
/// genuinely hung task surfaces as an ``AsyncEventProbeTimeoutError`` naming the spy's probes (`<label>.completed`,
/// `<label>.observationsFinished`, `<label>.spawned`) rather than a silent suite hang. The overloads without a
/// clock use a `ContinuousClock` and the spy's ``defaultTimeout``.
public final class TaskProviderSpy: TaskProvider, Sendable {
    /// The count of one kind of task: spawns and completions as count-only probes, plus the handles that let
    /// the spy cancel the ones still running.
    private final class Tracker: Sendable {
        private struct Handles {
            var next: UInt64 = 0
            /// Live tasks by id. A task that was counted but not yet attached holds a no-op until it is.
            var cancels: [UInt64: @Sendable () -> Void] = [:]
        }

        let spawned: AsyncEventProbe<Never>
        let finished: AsyncEventProbe<Never>
        private let handles = Mutex(Handles())

        init(spawned: AsyncEventProbe<Never>, finished: AsyncEventProbe<Never>) {
            self.spawned = spawned
            self.finished = finished
        }

        var liveCount: Int { handles.withLock { $0.cancels.count } }

        /// Counts a spawn, synchronously, and returns the id the task reports its end under.
        func begin() -> UInt64 {
            let id = handles.withLock { h in
                defer { h.next &+= 1 }
                h.cancels[h.next] = {}
                return h.next
            }
            spawned.record()
            return id
        }

        /// Keeps the means to cancel `task` until it ends. A task that already ended is not kept.
        func attach<Success: Sendable, Failure: Error>(_ id: UInt64, _ task: Task<Success, Failure>) {
            handles.withLock { h in
                if h.cancels[id] != nil { h.cancels[id] = { task.cancel() } }
            }
        }

        /// Forgets the task and counts its completion.
        func finish(_ id: UInt64) {
            handles.withLock { _ = $0.cancels.removeValue(forKey: id) }
            finished.record()
        }

        /// Cancels every task still running and forgets them. Cancelling a finished task is a no-op.
        func cancelAll() {
            let cancels = handles.withLock { h in
                let live = Array(h.cancels.values)
                h.cancels.removeAll()
                return live
            }
            for cancel in cancels { cancel() }
        }
    }

    private let work: Tracker
    private let observations: Tracker

    /// The deadline used by the waits that are not given one: 30 seconds unless the spy was created with another.
    /// It is a hang guard, not a latency assertion: a wait returns as soon as the tasks have settled, so a long default costs time only when a task is genuinely stuck, while a short one fails tests on a busy machine or under a sanitizer. Pass a shorter one to test a timeout itself, or use the clock-injectable forms.
    public let defaultTimeout: Duration

    /// - Parameters:
    ///   - label: Names the spy's probes in a timeout message.
    ///   - defaultTimeout: The deadline used by ``waitForAllTasks(timeout:)`` and its siblings when a call site
    ///     does not pass one.
    ///   - sourceLocation: Where the spy is created, reported by a timeout message.
    public init(
        label: String = "TaskProviderSpy",
        defaultTimeout: Duration = .seconds(30),
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        func probe(_ name: String) -> AsyncEventProbe<Never> {
            AsyncEventProbe(label: "\(label).\(name)", sourceLocation: sourceLocation)
        }
        work = Tracker(spawned: probe("spawned"), finished: probe("completed"))
        observations = Tracker(spawned: probe("observationsSpawned"), finished: probe("observationsFinished"))
        self.defaultTimeout = defaultTimeout
    }

    deinit {
        cancelObservations()
        cancelPendingWork()
    }

    /// `.work` tasks spawned so far (the ones `waitForAllTasks` settles).
    public var spawnedCount: Int { work.spawned.count }
    /// `.work` tasks that have finished.
    public var completedCount: Int { work.finished.count }
    /// `.work` tasks still in flight.
    public var liveCount: Int { work.spawned.count - work.finished.count }
    /// `.observation` tasks that have not finished yet.
    public var observationCount: Int { observations.spawned.count - observations.finished.count }

    /// How many work tasks the spy still holds a handle to. For tests of the bookkeeping itself.
    var trackedWorkHandleCount: Int { work.liveCount }

    /// How many ``waitForSpawnedTasks(atLeast:within:clock:)`` calls are parked. Lets a test wait for one to
    /// register before it spawns.
    var spawnWaiterCount: Int { work.spawned.waiterCount }

    // MARK: - Teardown

    /// Cancels every `.work` task that is still running. Cancelling a finished task is a no-op, so this is safe
    /// to call at any point. A cancelled task still counts as completed once its body ends.
    public func cancelPendingWork() { work.cancelAll() }

    /// Cancels every `.observation` task that is still running.
    public func cancelObservations() { observations.cancelAll() }

    // MARK: - Waiting

    /// Suspend until at least `count` `.work` tasks have been spawned, racing a `clock`-driven deadline. For a
    /// test that must drive a task's input after the task started.
    public func waitForSpawnedTasks<C: Clock>(atLeast count: Int, within duration: C.Duration, clock: C) async throws {
        try await work.spawned.wait(forAtLeast: count, within: duration, clock: clock)
    }

    /// Convenience over `ContinuousClock` and ``defaultTimeout``.
    public func waitForSpawnedTasks(atLeast count: Int, timeout: Duration? = nil) async throws {
        try await waitForSpawnedTasks(atLeast: count, within: timeout ?? defaultTimeout, clock: ContinuousClock())
    }

    /// Settle every `.work` task transitively, racing a `clock`-driven deadline. Call
    /// *after* triggering the work (the spawn is recorded synchronously by `task`, so
    /// at least one spawn is visible by the time this is awaited). Throws
    /// `AsyncEventProbeTimeoutError` if a task hangs past the deadline.
    ///
    /// `duration` is a single **global** budget: the deadline is fixed once, and each
    /// re-check waits only for the time *remaining* against it. (Passing `duration` afresh
    /// per round would let the effective timeout grow to `rounds × duration` under a real
    /// clock.)
    ///
    /// - Important: This observes only work registered through the spy, and only when the spawn is registered
    ///   before the spawning task returns (the normal case: production code calls `taskProvider.task { … }`
    ///   synchronously inside the parent's body). Work spawned through a raw `Task { }`, or registered after
    ///   its parent has already completed, is invisible here and may still be pending when this returns.
    public func waitForAllTasks<C: Clock>(within duration: C.Duration, clock: C) async throws {
        try await settle(work, within: duration, clock: clock)
    }

    /// Convenience over `ContinuousClock` and ``defaultTimeout``.
    public func waitForAllTasks(timeout: Duration? = nil) async throws {
        try await waitForAllTasks(within: timeout ?? defaultTimeout, clock: ContinuousClock())
    }

    /// Suspend until every `.observation` task has finished, racing a `clock`-driven deadline.
    ///
    /// Observations only finish when their input ends or they are cancelled, so call this after tearing the
    /// system under test down (or after finishing its input streams). Observations spawned while waiting are
    /// awaited too; the deadline covers the whole wait.
    public func waitForObservationsToFinish<C: Clock>(within duration: C.Duration, clock: C) async throws {
        try await settle(observations, within: duration, clock: clock)
    }

    /// Convenience over `ContinuousClock` and ``defaultTimeout``.
    public func waitForObservationsToFinish(timeout: Duration? = nil) async throws {
        try await waitForObservationsToFinish(within: timeout ?? defaultTimeout, clock: ContinuousClock())
    }

    /// Waits for everything `tracker` has spawned to finish, including what is spawned while waiting.
    private func settle<C: Clock>(_ tracker: Tracker, within duration: C.Duration, clock: C) async throws {
        let deadline = clock.now.advanced(by: duration)
        while true {
            let target = tracker.spawned.count
            if target == 0 { return }
            let remaining = clock.now.duration(to: deadline)
            try await tracker.finished.wait(forAtLeast: target, within: remaining, clock: clock)
            if tracker.spawned.count == target { return }
        }
    }

    // MARK: - TaskProvider

    @discardableResult
    public func task<Success: Sendable>(
        role: TaskRole,
        priority: TaskPriority?,
        @_inheritActorContext operation: sending @escaping @isolated(any) () async -> Success
    ) -> Task<Success, Never> {
        let tracker = role == .work ? work : observations
        let id = tracker.begin()
        let task = Task(priority: priority) {
            defer { tracker.finish(id) }
            return await operation()
        }
        tracker.attach(id, task)
        return task
    }

    @discardableResult
    public func task<Success: Sendable>(
        role: TaskRole,
        priority: TaskPriority?,
        @_inheritActorContext operation: sending @escaping @isolated(any) () async throws -> Success
    ) -> Task<Success, any Error> {
        let tracker = role == .work ? work : observations
        let id = tracker.begin()
        let task = Task(priority: priority) {
            defer { tracker.finish(id) }
            return try await operation()
        }
        tracker.attach(id, task)
        return task
    }
}

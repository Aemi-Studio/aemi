import AemiCore
import Foundation
import Synchronization

/// Tracking ``TaskProvider`` test double that lets a test await the real completion of spawned
/// tasks instead of polling.
///
/// Every spawned work task is tracked: the spy counts the spawn immediately and the completion
/// once the task finishes. Tests then await real boundaries:
/// ``waitForAllTasks(timeout:)`` suspends until every registered task (including tasks registered
/// while waiting) has finished, and ``waitForSpawnedTasks(atLeast:timeout:)`` suspends until a
/// task exists at all (for tests that must drive a task's input after it started). Both fail fast
/// with a `CountProbeTimeoutError` instead of hanging.
///
/// The two counters are payload-free `CountProbe<Never>`s, so the spy keeps a running count of work
/// it spawns and completes without retaining a backing array.
///
/// It lives in `AemiTesting` — a module that only links into test targets — so it can conform to
/// ``TaskProvider`` directly with no `#if DEBUG` guard, instead of needing a `@retroactive`
/// conformance shim in each test target.
///
/// ## Teardown
///
/// Work and observation handles are both retained so they can be cancelled deterministically:
/// ``cancelPendingWork()`` and ``cancelObservations()`` cancel each kind, and `deinit` calls
/// both as a safety net so a forgotten teardown cannot leak a suspended task onto the shared test
/// executor.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
public final class TaskProviderSpy: TaskProvider {
    private let spawned: CountProbe<Never>
    private let completed: CountProbe<Never>
    private let observationsSpawned: CountProbe<Never>
    private let observationsFinished: CountProbe<Never>
    private let workCancels = Mutex<[UUID: @Sendable () -> Void]>([:])
    private let observationCancels = Mutex<[UUID: @Sendable () -> Void]>([:])
    private let label: String
    private let defaultTimeout: Duration
    private let file: StaticString
    private let function: String
    private let line: UInt

    /// Creates a spy. The creation site is reported by timeout errors.
    ///
    /// - Parameter defaultTimeout: The deadline used by ``waitForAllTasks(timeout:)`` and
    ///   ``waitForSpawnedTasks(atLeast:timeout:)`` when a call site does not pass one. Raise it for
    ///   a suite that runs heavier work under load.
    public init(
        label: String = "TaskProviderSpy",
        defaultTimeout: Duration = .seconds(1),
        file: StaticString = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        self.label = label
        self.defaultTimeout = defaultTimeout
        self.file = file
        self.function = function
        self.line = line
        spawned = CountProbe(label: "\(label).spawned", file: file, function: function, line: line)
        completed = CountProbe(label: "\(label).completed", file: file, function: function, line: line)
        observationsSpawned = CountProbe(
            label: "\(label).observationsSpawned", file: file, function: function, line: line
        )
        observationsFinished = CountProbe(
            label: "\(label).observationsFinished", file: file, function: function, line: line
        )
    }

    deinit {
        cancelObservations()
        cancelPendingWork()
    }

    /// Number of tasks registered so far.
    public var spawnedTaskCount: Int {
        spawned.count
    }

    /// Number of registered tasks that have finished.
    public var completedTaskCount: Int {
        completed.count
    }

    /// Number of registered work tasks that have not finished yet.
    public var pendingWorkTaskCount: Int {
        workCancels.withLock(\.count)
    }

    /// Number of tracked flow-lifetime observers that have not finished yet.
    public var observationCount: Int {
        observationCancels.withLock(\.count)
    }

    /// Tracks a task: counts the spawn immediately, and the completion once the task finishes. The
    /// task itself is not altered — a monitor awaits its result on the side — but its cancel handle
    /// is retained until it finishes so ``cancelPendingWork()`` and `deinit` can tear it down.
    func register(work task: Task<some Sendable, some Error>) {
        let id = UUID()
        spawned.record()
        workCancels.withLock { $0[id] = { task.cancel() } }
        Task { [weak self, completed] in
            _ = await task.result
            self?.workCancels.withLock { $0[id] = nil }
            completed.record()
        }
    }

    /// Tracks a flow-lifetime observer. Excluded from ``waitForAllTasks(timeout:)`` and
    /// ``waitForSpawnedTasks(atLeast:timeout:)`` — observers only finish when their input ends
    /// or ``cancelObservations()`` runs. ``waitForObservationsToFinish(timeout:)`` awaits that
    /// moment; a monitor counts the completion on the side, like the work counters.
    func register(observation task: Task<some Sendable, some Error>) {
        let id = UUID()
        observationsSpawned.record()
        observationCancels.withLock { $0[id] = { task.cancel() } }
        Task { [weak self, observationsFinished] in
            _ = await task.result
            self?.observationCancels.withLock { $0[id] = nil }
            observationsFinished.record()
        }
    }

    /// Cancels every outstanding work task and stops tracking it. Cancelling an already-finished
    /// task is a no-op, so this is safe to call at any point.
    public func cancelPendingWork() {
        let cancels = workCancels.withLock { cancels in
            let snapshot = Array(cancels.values)
            cancels.removeAll()
            return snapshot
        }
        for cancel in cancels {
            cancel()
        }
    }

    /// Cancels every tracked observer and stops tracking it.
    public func cancelObservations() {
        let cancels = observationCancels.withLock { cancels in
            let snapshot = Array(cancels.values)
            cancels.removeAll()
            return snapshot
        }
        for cancel in cancels {
            cancel()
        }
    }

    /// Suspends until at least `count` tasks have been registered, or the timeout elapses.
    public func waitForSpawnedTasks(atLeast count: Int, timeout: Duration? = nil) async throws {
        try await spawned.wait(forAtLeast: count, timeout: timeout ?? defaultTimeout)
    }

    /// Suspends until every registered task has finished, or the timeout elapses.
    ///
    /// Tasks registered while waiting are awaited too, so chains of fire-and-forget work (a task
    /// spawning another task) complete in one call. The deadline covers the whole wait: a chain
    /// that keeps respawning past it throws a `CountProbeTimeoutError` instead of extending the
    /// wait indefinitely.
    ///
    /// - Important: This observes only work registered through the spy, and only when the spawn is
    ///   registered before the spawning task returns (the normal case: production code calls
    ///   `taskProvider.task { … }` synchronously inside the parent's body). Work spawned through a
    ///   raw `Task { }`, or registered after its parent has already completed, is invisible here and
    ///   may still be pending when this returns.
    public func waitForAllTasks(timeout: Duration? = nil) async throws {
        // The safety deadline runs on a real `ContinuousClock` on purpose: it must fire even when
        // the system under test is driven by an injected fake clock (e.g. `TestClock`), so a
        // stalled or runaway spawn chain fails fast instead of hanging the suite.
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout ?? defaultTimeout)
        while true {
            let target = spawned.count
            let remaining = max(.zero, clock.now.duration(to: deadline))
            try await completed.wait(forAtLeast: target, timeout: remaining)
            if spawned.count == target {
                return
            }
            guard clock.now < deadline else {
                throw CountProbeTimeoutError<Never>(
                    label: "\(label).completed",
                    expected: spawned.count,
                    recordedCount: completed.count,
                    recorded: completed.events,
                    file: file,
                    function: function,
                    line: line
                )
            }
        }
    }

    /// Suspends until every tracked observer has finished, or the timeout elapses.
    ///
    /// Observers only finish when their input ends or they are cancelled, so call this after
    /// tearing the system under test down (or after finishing its input streams). Observers
    /// registered while waiting are awaited too; the deadline covers the whole wait.
    public func waitForObservationsToFinish(timeout: Duration? = nil) async throws {
        // Same real-clock deadline rationale as `waitForAllTasks`: the wait must fail fast
        // even when the system under test runs on an injected fake clock.
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout ?? defaultTimeout)
        while true {
            let target = observationsSpawned.count
            let remaining = max(.zero, clock.now.duration(to: deadline))
            try await observationsFinished.wait(forAtLeast: target, timeout: remaining)
            if observationsSpawned.count == target {
                return
            }
            guard clock.now < deadline else {
                throw CountProbeTimeoutError<Never>(
                    label: "\(label).observationsFinished",
                    expected: observationsSpawned.count,
                    recordedCount: observationsFinished.count,
                    recorded: observationsFinished.events,
                    file: file,
                    function: function,
                    line: line
                )
            }
        }
    }

    // MARK: - TaskProvider

    @discardableResult
    public func task<Success: Sendable>(
        role: TaskRole,
        priority: TaskPriority?,
        @_inheritActorContext @_implicitSelfCapture
        operation: sending @escaping @isolated(any) () async -> Success
    ) -> Task<Success, Never> {
        let task = Task(priority: priority, operation: operation)
        switch role {
        case .work:
            register(work: task)
        case .observation:
            register(observation: task)
        }
        return task
    }

    @discardableResult
    public func task<Success: Sendable>(
        role: TaskRole,
        priority: TaskPriority?,
        @_inheritActorContext @_implicitSelfCapture
        operation: sending @escaping @isolated(any) () async throws -> Success
    ) -> Task<Success, Error> {
        let task = Task(priority: priority, operation: operation)
        switch role {
        case .work:
            register(work: task)
        case .observation:
            register(observation: task)
        }
        return task
    }

    @discardableResult
    public func detachedTask<Success: Sendable>(
        role: TaskRole,
        priority: TaskPriority?,
        operation: sending @escaping @isolated(any) () async -> Success
    ) -> Task<Success, Never> {
        let task = Task.detached(priority: priority, operation: operation)
        switch role {
        case .work:
            register(work: task)
        case .observation:
            register(observation: task)
        }
        return task
    }

    @discardableResult
    public func detachedTask<Success: Sendable>(
        role: TaskRole,
        priority: TaskPriority?,
        operation: sending @escaping @isolated(any) () async throws -> Success
    ) -> Task<Success, Error> {
        let task = Task.detached(priority: priority, operation: operation)
        switch role {
        case .work:
            register(work: task)
        case .observation:
            register(observation: task)
        }
        return task
    }
}

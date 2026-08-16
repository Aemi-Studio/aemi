/// The role a spawned task plays, which governs whether a `TaskProviderSpy` must
/// settle it. `.work` is application work the spy waits for transitively;
/// `.observation` is a long-lived stream / observation loop that never completes on
/// its own, so the spy excludes it from `waitForAllTasks()` (waiting on it would
/// hang the suite). Library seams default new tasks to `.work` and tag only the
/// genuinely-unbounded loops `.observation`.
public enum TaskRole: Sendable, Hashable {
    case work
    case observation
}

/// A seam mirroring `Task.init` so async-heavy library code can spawn tasks through
/// an injected provider instead of a raw `Task { }`. The shipped default is
/// `LiveTaskProvider` (a transparent forward to `Task.init`); tests inject a
/// `TaskProviderSpy` and `await waitForAllTasks()` to settle the real handles
/// deterministically rather than racing on serial-result comparison.
///
/// The requirement carries `sending` + `@isolated(any)` so an isolated operation
/// crosses into the task exactly as `Task.init` allows; `@_inheritActorContext`
/// keeps a `taskProvider.task { }` call site inheriting the caller's actor where the
/// closure is formed directly (the convenience forms below form it directly).
public protocol TaskProvider: Sendable {
    @discardableResult
    func task<Success: Sendable>(
        role: TaskRole,
        priority: TaskPriority?,
        @_inheritActorContext operation: sending @escaping @isolated(any) () async -> Success
    ) -> Task<Success, Never>

    @discardableResult
    func task<Success: Sendable>(
        role: TaskRole,
        priority: TaskPriority?,
        @_inheritActorContext operation: sending @escaping @isolated(any) () async throws -> Success
    ) -> Task<Success, any Error>
}

extension TaskProvider {
    /// Ergonomic, recursion-free convenience: defaults `role`/`priority` and takes a
    /// trailing closure. The unlabeled `_ operation` selector differs from the
    /// labeled `operation:` requirement, so the forward below resolves to the
    /// requirement (never to itself).
    @discardableResult
    public func task<Success: Sendable>(
        role: TaskRole = .work,
        priority: TaskPriority? = nil,
        @_inheritActorContext _ operation: sending @escaping @isolated(any) () async -> Success
    ) -> Task<Success, Never> {
        task(role: role, priority: priority, operation: operation)
    }

    @discardableResult
    public func task<Success: Sendable>(
        role: TaskRole = .work,
        priority: TaskPriority? = nil,
        @_inheritActorContext _ operation:
            sending @escaping @isolated(any) () async throws -> Success
    ) -> Task<Success, any Error> {
        task(role: role, priority: priority, operation: operation)
    }
}

/// The shipped default: a transparent forward to `Task.init`, so a library that
/// takes a `TaskProvider` parameter defaulting to `LiveTaskProvider()` behaves
/// byte-for-byte like raw `Task { }` in production. `role` is irrelevant live (only
/// the spy reads it) and is accepted-and-ignored.
public struct LiveTaskProvider: TaskProvider {
    public init() {}

    @discardableResult
    public func task<Success: Sendable>(
        role: TaskRole,
        priority: TaskPriority?,
        @_inheritActorContext operation: sending @escaping @isolated(any) () async -> Success
    ) -> Task<Success, Never> {
        Task(priority: priority, operation: operation)
    }

    @discardableResult
    public func task<Success: Sendable>(
        role: TaskRole,
        priority: TaskPriority?,
        @_inheritActorContext operation: sending @escaping @isolated(any) () async throws -> Success
    ) -> Task<Success, any Error> {
        Task(priority: priority, operation: operation)
    }
}

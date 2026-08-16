/// The production implementation: forwards to `Task.init` / `Task.detached` unchanged,
/// regardless of role.
///
/// - Note: ``task(role:priority:operation:)`` spawns non-detached, so the work inherits the
///   caller's actor context — what production fire-and-forget work wants by default.
///   ``detachedTask(role:priority:operation:)`` is the deliberate opt-out for work that needs
///   its own isolation; it forwards to `Task.detached`, so the closure runs off the caller's
///   actor. Prefer it over reaching for `Task.detached` at the call site, so tests keep seeing
///   the spawn.
public struct DefaultTaskProvider: TaskProvider {
    public init() {}

    @discardableResult
    public func task<Success: Sendable>(
        role _: TaskRole,
        priority: TaskPriority?,
        @_inheritActorContext @_implicitSelfCapture
        operation: sending @escaping @isolated(any) () async -> Success
    ) -> Task<Success, Never> {
        Task(priority: priority, operation: operation)
    }

    @discardableResult
    public func task<Success: Sendable>(
        role _: TaskRole,
        priority: TaskPriority?,
        @_inheritActorContext @_implicitSelfCapture
        operation: sending @escaping @isolated(any) () async throws -> Success
    ) -> Task<Success, Error> {
        Task(priority: priority, operation: operation)
    }

    @discardableResult
    public func detachedTask<Success: Sendable>(
        role _: TaskRole,
        priority: TaskPriority?,
        operation: sending @escaping @isolated(any) () async -> Success
    ) -> Task<Success, Never> {
        Task.detached(priority: priority, operation: operation)
    }

    @discardableResult
    public func detachedTask<Success: Sendable>(
        role _: TaskRole,
        priority: TaskPriority?,
        operation: sending @escaping @isolated(any) () async throws -> Success
    ) -> Task<Success, Error> {
        Task.detached(priority: priority, operation: operation)
    }
}

public extension TaskProvider where Self == DefaultTaskProvider {
    static var `default`: DefaultTaskProvider {
        DefaultTaskProvider()
    }
}

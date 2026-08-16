/// Injection point for spawning unstructured tasks.
///
/// Production code creates fire-and-forget work through this protocol instead of calling
/// `Task.init` directly, so tests can substitute a tracking double and await the actual
/// completion of spawned work instead of polling.
///
/// The ``task(role:priority:operation:)`` signatures mirror `Task.init`: the `operation` closure
/// carries the same `@_inheritActorContext`, `@_implicitSelfCapture`, `sending`, and
/// `@isolated(any)` treatment, so a closure literal both inherits the caller's actor context and
/// may reference `self` implicitly, exactly like `Task { ... }`. Adopting the provider is
/// therefore a textual substitution of `Task {` with `taskProvider.task {`.
///
/// The ``detachedTask(role:priority:operation:)`` signatures mirror `Task.detached` instead.
/// Detachment cannot be expressed as a ``TaskRole`` case because a closure's isolation is fixed
/// at the call site by the parameter's declared attributes: `@_inheritActorContext` binds the
/// caller's actor context into the closure literal the moment it is formed, before any runtime
/// `role` value could be inspected. The detached family therefore drops `@_inheritActorContext`
/// (so a closure literal stays nonisolated and runs off the caller's actor) and
/// `@_implicitSelfCapture` (so a `self` capture must be spelled out, exactly as with
/// `Task.detached`).
///
/// `role:` and `priority:` are required on the protocol methods; convenience overloads default
/// them to `.work` / `nil`, so the common spellings stay `taskProvider.task { … }` and
/// `taskProvider.detachedTask { … }`.
public protocol TaskProvider: Sendable {
    @discardableResult
    func task<Success: Sendable>(
        role: TaskRole,
        priority: TaskPriority?,
        @_inheritActorContext @_implicitSelfCapture
        operation: sending @escaping @isolated(any) () async -> Success
    ) -> Task<Success, Never>

    // TODO: [SE-0520] The Swift 6.4 stdlib drops the implicit `@discardableResult` from throwing
    // `Task` initializers (ignoring a throwing task silently drops its error).
    @discardableResult
    func task<Success: Sendable>(
        role: TaskRole,
        priority: TaskPriority?,
        @_inheritActorContext @_implicitSelfCapture
        operation: sending @escaping @isolated(any) () async throws -> Success
    ) -> Task<Success, Error>

    /// Spawns a task that does **not** inherit the caller's actor context, mirroring
    /// `Task.detached`. See the type-level discussion for why detachment is a separate method
    /// family rather than a ``TaskRole`` case, and why `operation` deliberately carries neither
    /// `@_inheritActorContext` nor `@_implicitSelfCapture`.
    @discardableResult
    func detachedTask<Success: Sendable>(
        role: TaskRole,
        priority: TaskPriority?,
        operation: sending @escaping @isolated(any) () async -> Success
    ) -> Task<Success, Never>

    /// Throwing variant of ``detachedTask(role:priority:operation:)``, mirroring
    /// `Task.detached`'s throwing overload.
    @discardableResult
    func detachedTask<Success: Sendable>(
        role: TaskRole,
        priority: TaskPriority?,
        operation: sending @escaping @isolated(any) () async throws -> Success
    ) -> Task<Success, Error>
}

public extension TaskProvider {
    @discardableResult
    func task<Success: Sendable>(
        role: TaskRole = .work,
        priority: TaskPriority? = nil,
        @_inheritActorContext @_implicitSelfCapture
        operation: sending @escaping @isolated(any) () async -> Success
    ) -> Task<Success, Never> {
        task(role: role, priority: priority, operation: operation)
    }

    @discardableResult
    func task<Success: Sendable>(
        role: TaskRole = .work,
        priority: TaskPriority? = nil,
        @_inheritActorContext @_implicitSelfCapture
        operation: sending @escaping @isolated(any) () async throws -> Success
    ) -> Task<Success, Error> {
        task(role: role, priority: priority, operation: operation)
    }

    @discardableResult
    func detachedTask<Success: Sendable>(
        role: TaskRole = .work,
        priority: TaskPriority? = nil,
        operation: sending @escaping @isolated(any) () async -> Success
    ) -> Task<Success, Never> {
        detachedTask(role: role, priority: priority, operation: operation)
    }

    @discardableResult
    func detachedTask<Success: Sendable>(
        role: TaskRole = .work,
        priority: TaskPriority? = nil,
        operation: sending @escaping @isolated(any) () async throws -> Success
    ) -> Task<Success, Error> {
        detachedTask(role: role, priority: priority, operation: operation)
    }
}

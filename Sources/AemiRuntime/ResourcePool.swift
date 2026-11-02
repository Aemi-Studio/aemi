private import Synchronization

/// A resource a `ResourcePool` can construct from a filesystem path. The single failable
/// factory mirrors the acquisition pattern of a file / database / socket handle: it returns
/// `nil` when the resource cannot be opened. Conforming a concrete handle that already has an
/// `init?(path:)` is a one-line `extension MyHandle: PooledResource {}`.
///
/// The point of the generic is decoupling: the extracted HTTP server pools `some
/// PooledResource` and therefore does NOT depend on any persistence package — the application
/// chooses the concrete `Resource` (a DB connection, say) at its composition root.
public protocol PooledResource: Sendable {
    /// Open the resource for `path`, or `nil` if it cannot be opened.
    init?(path: String)
}

/// Why a `ResourcePool` could not be built. Thrown only by the diagnostic
/// `init(diagnostic:count:)`; the failable `init?` still collapses every cause to `nil` for
/// callers that only need go/no-go. The associated values pin the FAILING resource so a
/// caller can log "resource N of M failed to open" instead of a bare "pool is nil".
public enum ResourcePoolError: Error, Sendable {
    /// `Resource(path:)` returned `nil` while opening the resource at `index` (0-based) of a
    /// pool of `count`. The factory is failable, not throwing, so there is no underlying error
    /// to surface — `path`/`index`/`count` are everything the pool knows about the failure.
    case resourceUnavailable(index: Int, count: Int, path: String)
}

/// A fixed-size pool of `count` pre-opened `Resource`s with wait-free checkout, and an `async` ``acquire()`` that waits
/// for one when all are out.
///
/// Checkout happens INSIDE the work that needs a resource, so at most `count` are out at once
/// and a checkout never blocks (it returns `nil` when momentarily drained — the caller decides
/// the policy). The free-list is a `Mutex`, not an actor: pop/append is a trivial critical
/// section with no serial-executor funnel. One `Resource` is touched by one task at a time, so
/// a handle carrying a "single-threaded use" invariant (e.g. a C database handle) stays sound.
///
/// Generalized from apple-docs' server `ConnectionPool` so the seam can be shared by the
/// extracted server and an async database façade without either depending on the other.
public final class ResourcePool<Resource: Sendable>: Sendable {
    /// The free resources and the tasks waiting in ``acquire()``, oldest first.
    private struct State {
        var free: [Resource]
        var waiters: [(id: UInt64, continuation: CheckedContinuation<Resource, any Error>)] = []
        var nextWaiter: UInt64 = 0
    }

    private let state: Mutex<State>
    /// The number of resources the pool was built with (its maximum concurrent checkouts).
    public let count: Int

    /// Build a pool of `max(1, count)` resources from `make`, called with each index in order; the first error it
    /// throws is rethrown and no pool is built. The factory form for resources that are not opened from a path (a
    /// worker slot, a scratch directory per index).
    public init<Failure: Error>(count: Int, make: (_ index: Int) throws(Failure) -> Resource) throws(Failure) {
        let target = max(1, count)
        var resources: [Resource] = []
        resources.reserveCapacity(target)
        for index in 0 ..< target { resources.append(try make(index)) }
        state = Mutex(State(free: resources))
        self.count = resources.count
    }

    /// Pop a free resource, or `nil` when all `count` are currently checked out.
    public func checkout() -> Resource? { state.withLock { $0.free.popLast() } }

    /// A free resource, waiting for a ``checkin(_:)`` when all are out; waiters are served oldest first.
    /// - Throws: `CancellationError` when the calling task is cancelled while it waits; it then holds nothing.
    public func acquire() async throws -> Resource {
        if let resource = checkout() { return resource }
        let id = state.withLock { state -> UInt64 in
            state.nextWaiter += 1
            return state.nextWaiter
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Under the lock that `onCancel` also takes: a cancellation either came before (the flag is set, so
                // the waiter is never registered) or comes after (it finds the waiter and resumes it).
                let outcome: AcquireOutcome<Resource> = state.withLock { state in
                    if let resource = state.free.popLast() { return .served(resource) }
                    if Task.isCancelled { return .cancelled }
                    state.waiters.append((id, continuation))
                    return .waiting
                }
                switch outcome {
                    case .served(let resource): continuation.resume(returning: resource)
                    case .cancelled: continuation.resume(throwing: CancellationError())
                    case .waiting: break
                }
            }
        } onCancel: {
            let waiter = state.withLock { state -> CheckedContinuation<Resource, any Error>? in
                guard let index = state.waiters.firstIndex(where: { $0.id == id }) else { return nil }
                return state.waiters.remove(at: index).continuation
            }
            waiter?.resume(throwing: CancellationError())
        }
    }

    /// Return a resource to the pool: to the oldest waiting ``acquire()`` if any, else to the free-list. Prefer
    /// `lease()`, which does this automatically.
    public func checkin(_ resource: Resource) {
        let waiter = state.withLock { state -> CheckedContinuation<Resource, any Error>? in
            guard !state.waiters.isEmpty else {
                state.free.append(resource)
                return nil
            }
            return state.waiters.removeFirst().continuation
        }
        waiter?.resume(returning: resource)
    }
}

/// What ``ResourcePool/acquire()`` found under the lock.
private enum AcquireOutcome<Resource> {
    case served(Resource)
    case cancelled
    case waiting
}

extension ResourcePool where Resource: PooledResource {
    /// Build a pool of `max(1, count)` resources by opening `Resource(path:)` that many times.
    /// `nil` if ANY open fails — the pool is all-or-nothing, so a partial pool never ships.
    ///
    /// The historical, source-stable entry point: it collapses every failure to `nil`. When you
    /// need to know WHICH resource failed (to log it), use the throwing `init(diagnostic:count:)`
    /// below — it discards its `ResourcePoolError` with `try?`.
    public convenience init?(path: String, count: Int) {
        try? self.init(diagnostic: path, count: count)
    }

    /// Build the pool, THROWING `ResourcePoolError.resourceUnavailable(index:count:path:)` at the
    /// first `Resource(path:)` that returns `nil` — so a caller (ADDBAsync/ADServe/apple-docs) can
    /// report exactly which of the `count` opens failed instead of a bare "pool is nil". Still
    /// all-or-nothing: a partial pool never ships. The failable `init?` above delegates here, so
    /// the two construction paths can never diverge.
    ///
    /// (`diagnostic:` is an internal argument label that only disambiguates this from the failable
    /// `init?(path:count:)`; the two overloads are otherwise identically shaped. Existing call
    /// sites that wrote `ResourcePool(path:count:)` keep resolving to the failable initializer, so
    /// source compatibility for this zero-dependency leaf is preserved.)
    public convenience init(diagnostic path: String, count: Int) throws(ResourcePoolError) {
        let target = max(1, count)
        try self.init(count: target) { index throws(ResourcePoolError) in
            guard let resource = Resource(path: path) else {
                throw .resourceUnavailable(index: index, count: target, path: path)
            }
            return resource
        }
    }
}

/// A single-owner, compile-enforced borrow of a pooled `Resource`. Noncopyable, so it cannot be
/// duplicated (no double-checkout) and the resource returns to the pool on `deinit` at every
/// scope exit — replacing a manual `checkout()` + `defer { checkin() }` pair, where an early
/// `return` between the two would silently leak a resource. Obtain one with `ResourcePool.lease()`.
public struct ResourceLease<Resource: Sendable>: ~Copyable {
    /// The borrowed resource — valid for the lease's lifetime; returned to the pool on `deinit`.
    public let resource: Resource
    private let pool: ResourcePool<Resource>

    fileprivate init(resource: Resource, pool: ResourcePool<Resource>) {
        self.resource = resource
        self.pool = pool
    }

    deinit { pool.checkin(resource) }
}

extension ResourcePool {
    /// Borrow a resource as a noncopyable `ResourceLease` that auto-returns on scope exit.
    /// `nil` when the pool is momentarily drained (all `count` resources are checked out).
    public func lease() -> ResourceLease<Resource>? {
        guard let resource = checkout() else { return nil }
        return ResourceLease(resource: resource, pool: self)
    }

    /// Borrow a resource as a `ResourceLease`, waiting as ``acquire()`` does when all are out.
    public func acquireLease() async throws -> ResourceLease<Resource> {
        ResourceLease(resource: try await acquire(), pool: self)
    }
}

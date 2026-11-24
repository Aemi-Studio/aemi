//
//  AsyncExclusion.swift
//  HTTPConcurrency
//
//  Mutual exclusion for a critical section that must stay closed **across an `await`** — the case no
//  other tool in this package covers:
//
//  - `Mutex` (Synchronization) is a thread-blocking lock. Holding one across a suspension point is
//    not expressible, and holding one across a *socket wait* would park a cooperative thread on a
//    peer that may never act — the failure mode audit FLAKE-1 removed from the accept path.
//  - An `actor` does not serialize either: actor methods are **reentrant**, so a second caller enters
//    the moment the first `await`s. Actor isolation protects stored state between suspension points;
//    it says nothing about a multi-step operation that spans them.
//
//  So a holder here suspends the *Task* and releases the cooperative thread, exactly as ``AsyncGate``
//  does in the test tier — but with mutex semantics (acquire/release, FIFO hand-off) rather than a
//  permit gate. Continuations resume outside the lock, and a cancelled waiter unregisters without
//  consuming the hand-off.
//
//  CWE-833 (deadlock) is the standing hazard: this exclusion is NOT reentrant, and a body that
//  re-enters it on the same task waits forever. Callers keep the ungated core of a critical section in
//  a separate method and take the exclusion once, at the outermost entry point.
//

internal import Synchronization

/// A non-reentrant mutual exclusion that suspends its waiters instead of blocking a thread.
///
/// Use it when a critical section spans an `await` — otherwise use `Mutex`, which is cheaper and
/// enforced by the type system. Hand-off is FIFO, so a waiter cannot be starved by a stream of later
/// arrivals, and cancellation is honored while queued: a cancelled waiter throws `CancellationError`,
/// unregisters, and leaves the exclusion for the next in line.
public final class AsyncExclusion: Sendable {
    /// One suspended caller — either queued for the exclusion or parked in
    /// ``waitForWaiters(atLeast:)`` until the queue reaches `threshold` (`0` for the former).
    ///
    /// SE-0458 (ADR 0009): `@safe` because the continuation never escapes this file and is resumed
    /// exactly once — a waiter is *removed from its queue under the lock* in the same step that
    /// yields it to a resumer, so no second resumal can be produced.
    @safe
    private struct Waiter {
        let id: UInt64
        let threshold: Int
        let continuation: UnsafeContinuation<Void, any Error>

        /// Resumes the parked caller, throwing `error` into it when one is given.
        func settle(throwing error: (any Error)? = nil) {
            if let error {
                unsafe continuation.resume(throwing: error)
            } else {
                unsafe continuation.resume()
            }
        }
    }

    private struct State {
        /// Whether a holder owns the exclusion.
        ///
        /// Stays `true` across a FIFO hand-off: ownership moves directly from the releasing holder to
        /// the woken waiter, so no third party can cut in between them.
        var isHeld = false
        var nextID: UInt64 = 0
        /// FIFO. `removeFirst()` is O(n), which is the right trade at the depths this serves (a
        /// per-connection direction has one holder and a handful of waiters); a ring buffer would
        /// cost an allocation per instance to save nothing measurable.
        var waiters: [Waiter] = []
        var countWaiters: [Waiter] = []

        mutating func makeID() -> UInt64 {
            nextID &+= 1
            return nextID
        }

        /// Removes and returns the ``waitForWaiters(atLeast:)`` parkers the current queue depth has
        /// satisfied — resumed by the caller, outside the lock.
        mutating func satisfiedCountWaiters() -> [Waiter] {
            let depth = waiters.count
            var woken: [Waiter] = []
            countWaiters.removeAll { waiter in
                guard waiter.threshold <= depth else {
                    return false
                }
                woken.append(waiter)
                return true
            }
            return woken
        }
    }

    /// What ``acquire()`` / ``waitForWaiters(atLeast:)`` decided under the lock.
    private enum Admission {
        /// Proceed at once — the exclusion was free, or the bar was already met.
        case proceed
        /// The task was already cancelled; never take the exclusion.
        case cancelled
        /// Parked; a resumer owns the continuation now.
        case parked
    }

    private let state = Mutex(State())

    /// An unheld exclusion with no waiters.
    public init() {
        // All state is default-initialized; the memberwise defaults on `State` are the whole setup.
    }

    deinit {
        // No teardown beyond ARC. A suspended waiter's cancellation handler retains `self`, so the
        // instance cannot be released while anyone is parked on it.
    }

    /// Whether a holder currently owns the exclusion.
    ///
    /// A diagnostic, and the oracle a caller asserts its serialization discipline against — a claim
    /// in a comment cannot fail, `precondition(exclusion.isHeld)` can.
    public var isHeld: Bool { state.withLock(\.isHeld) }

    /// Callers currently suspended waiting for the exclusion.
    public var waiterCount: Int { state.withLock(\.waiters.count) }

    /// Runs `body` with exclusive access, suspending — never blocking — until the holder ahead of it
    /// releases.
    ///
    /// The exclusion is released however `body` ends: return, `throw`, or cancellation. A caller
    /// cancelled *while queued* throws `CancellationError` without running `body`; one cancelled
    /// after it has been handed the exclusion also throws before `body` runs, and still releases.
    public func withExclusiveAccess<T>(_ body: () async throws -> T) async throws -> T {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await body()
    }

    /// Suspends until at least `count` callers are queued on the exclusion.
    ///
    /// The deterministic replacement for a `Task.yield()` spin when sequencing an interleaving: it
    /// lets a caller assert *at* the contended moment rather than hope to observe it. Mirrors
    /// ``AsyncGate/waitForWaiters(atLeast:)`` in the test tier.
    public func waitForWaiters(atLeast count: Int) async throws {
        if count <= 0 {
            return
        }
        let id = state.withLock { $0.makeID() }
        try await withTaskCancellationHandler {
            // Keep the closure parameter clause on the brace line for swiftlint
            // (closure_parameter_position); the collapsed signature exceeds swift-format's lineLength.
            try await unsafe withUnsafeThrowingContinuation {
                (continuation: UnsafeContinuation<Void, any Error>) in
                // SE-0458 (ADR 0009): boxing the continuation is the one unsafe step; every resumal
                // below goes through the `@safe` ``Waiter``.
                let parker = unsafe Waiter(id: id, threshold: count, continuation: continuation)
                let admission = state.withLock { s -> Admission in
                    if Task.isCancelled {
                        return .cancelled
                    }
                    if s.waiters.count >= count {
                        return .proceed
                    }
                    s.countWaiters.append(parker)
                    return .parked
                }
                Self.settle(parker, admission)
            }
        } onCancel: {
            unpark(id: id, from: \.countWaiters)?.settle(throwing: CancellationError())
        }
    }

    /// Takes the exclusion, suspending if a holder owns it.
    private func acquire() async throws {
        let id = state.withLock { $0.makeID() }
        try await withTaskCancellationHandler {
            // Closure parameter clause on the brace line — see ``waitForWaiters(atLeast:)``.
            try await unsafe withUnsafeThrowingContinuation {
                (continuation: UnsafeContinuation<Void, any Error>) in
                // SE-0458 (ADR 0009): see ``waitForWaiters(atLeast:)``.
                let claimant = unsafe Waiter(id: id, threshold: 0, continuation: continuation)
                let outcome = state.withLock { s -> (Admission, [Waiter]) in
                    if Task.isCancelled {
                        return (.cancelled, [])
                    }
                    if !s.isHeld {
                        s.isHeld = true
                        return (.proceed, [])
                    }
                    s.waiters.append(claimant)
                    return (.parked, s.satisfiedCountWaiters())
                }
                for waiter in outcome.1 {
                    waiter.settle()
                }
                Self.settle(claimant, outcome.0)
            }
        } onCancel: {
            // A waiter already handed the exclusion by ``release()`` is no longer queued, so this
            // finds nothing and cannot double-resume: that caller proceeds, sees the cancellation at
            // the `checkCancellation` in ``withExclusiveAccess(_:)``, and releases on the way out.
            unpark(id: id, from: \.waiters)?.settle(throwing: CancellationError())
        }
    }

    /// Hands the exclusion to the longest-waiting caller, or marks it free.
    ///
    /// The continuation resumes outside the lock.
    private func release() {
        let next = state.withLock { s -> Waiter? in
            guard !s.waiters.isEmpty else {
                s.isHeld = false
                return nil
            }
            // Ownership transfers directly — `isHeld` deliberately stays `true`.
            return s.waiters.removeFirst()
        }
        next?.settle()
    }

    /// Removes the waiter registered under `id` from `queue`, for the caller to resume.
    private func unpark(id: UInt64, from queue: WritableKeyPath<State, [Waiter]>) -> Waiter? {
        state.withLock { s -> Waiter? in
            guard let index = s[keyPath: queue].firstIndex(where: { $0.id == id }) else {
                return nil
            }
            return s[keyPath: queue].remove(at: index)
        }
    }

    /// Resumes `waiter` for a decision that did not park it, outside the lock.
    private static func settle(_ waiter: Waiter, _ admission: Admission) {
        switch admission {
            case .proceed:
                waiter.settle()
            case .cancelled:
                waiter.settle(throwing: CancellationError())
            case .parked:
                break
        }
    }
}

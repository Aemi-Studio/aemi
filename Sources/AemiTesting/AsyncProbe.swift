import Foundation
import Synchronization

/// Typed signal buffer for tests that want per-element observation
/// and a synchronous "no buffered elements" assertion.
///
/// Production calls `send(_:)`; the test awaits `next()` for the next
/// element or `expectNoBufferedElements()` to assert quiescence.
/// `next()` suspends indefinitely waiting for a send (Swift Testing's
/// per-test time limit is the ultimate backstop if a test truly
/// hangs).
///
/// ## Quiescence
///
/// `expectNoBufferedElements()` is **synchronous** — it doesn't poll,
/// doesn't yield, doesn't sleep. It drains the buffer and closes the
/// probe atomically under a single lock acquisition. Pair with a
/// deterministic settle point (typically `TestClock.advance(by:)`
/// after `waitForSleepers()`) so "buffer is empty *now*" actually
/// means "no further signals can possibly arrive". Wall-clock
/// settle windows and executor-quiescence guessing are explicitly
/// rejected design choices.
///
/// ## Cancellation
///
/// `next()` is cancellation-aware. A cancelled awaiter is removed
/// from the waiter queue and resumed with `CancellationError`.
///
/// ## Example
///
/// ```swift
/// let probe = AsyncProbe<EditSnapshot>()
/// undoController.onDidCommit = { snapshot in probe.send(snapshot) }
/// for _ in 0..<5 { controller.scheduleCommit(50) { ... } }
/// try await clock.waitForSleepers()
/// await clock.advance(by: .milliseconds(60))
/// _ = try await probe.next()                // first (and only) fire
/// try probe.expectNoBufferedElements()      // exactly-one assertion
/// ```
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
public final class AsyncProbe<Element: Sendable>: Sendable {

    private let state: Mutex<State>

    private struct State {
        var buffer: [Element] = []
        var waiters: [Waiter] = []
        var nextWaiterID: UInt64 = 0
        var finished: Bool = false
    }

    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<Element?, any Error>
    }

    public init() {
        self.state = Mutex(State())
    }

    /// Delivers `element`. If a waiter is queued, resumes it directly
    /// (strict FIFO handoff). Otherwise the element joins the buffer
    /// and the next `next()` call drains it. After ``finish()``, sends
    /// are silently dropped.
    public func send(_ element: Element) {
        let waiter: CheckedContinuation<Element?, any Error>? = state.withLock { current in
            guard !current.finished else { return nil }
            if current.waiters.isEmpty {
                current.buffer.append(element)
                return nil
            }
            return current.waiters.removeFirst().continuation
        }
        waiter?.resume(returning: element)
    }

    /// Closes the probe. Resumes every queued waiter with `nil` so
    /// they can detect end-of-stream. Subsequent `send(_:)` calls
    /// are no-ops. Idempotent.
    public func finish() {
        let waiters: [CheckedContinuation<Element?, any Error>] =
            state.withLock { current in
                guard !current.finished else { return [] }
                current.finished = true
                let drained = current.waiters.map(\.continuation)
                current.waiters.removeAll()
                return drained
            }
        for w in waiters { w.resume(returning: nil) }
    }

    /// Returns the next element. Suspends on a `CheckedContinuation`
    /// if the buffer is empty and the probe isn't finished. Throws
    /// `CancellationError` if cancelled while waiting.
    public func next() async throws -> Element? {
        try Task.checkCancellation()

        let waiterID: UInt64 = state.withLock { current in
            current.nextWaiterID += 1
            return current.nextWaiterID
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (cont: CheckedContinuation<Element?, any Error>) in
                let outcome: NextOutcome = state.withLock { current in
                    if Task.isCancelled { return .cancelled }
                    if !current.buffer.isEmpty {
                        return .deliver(current.buffer.removeFirst())
                    }
                    if current.finished { return .finished }
                    current.waiters.append(Waiter(id: waiterID, continuation: cont))
                    return .queued
                }
                switch outcome {
                    case .deliver(let element): cont.resume(returning: element)
                    case .finished: cont.resume(returning: nil)
                    case .cancelled: cont.resume(throwing: CancellationError())
                    case .queued: break
                }
            }
        } onCancel: {
            let resumer: CheckedContinuation<Element?, any Error>? = state.withLock { current in
                guard let idx = current.waiters.firstIndex(where: { $0.id == waiterID })
                else { return nil }
                let cont = current.waiters[idx].continuation
                current.waiters.remove(at: idx)
                return cont
            }
            resumer?.resume(throwing: CancellationError())
        }
    }

    /// Synchronously asserts the probe's buffer is empty *right now*
    /// and atomically closes the probe.
    ///
    /// Throws ``AsyncProbeError/unexpectedElements(_:)`` carrying the
    /// stray elements if any are found. Call **after** a
    /// deterministic settle point so "the buffer is empty" actually
    /// means "no more signals can come".
    ///
    /// The drain + finish happen under a single lock acquisition so
    /// a `send()` racing against the assertion either lands fully
    /// before (and is reported) or fully after (and is silently
    /// dropped because `finished` is set) — never half-and-half.
    public func expectNoBufferedElements() throws {
        let strays: [Element] = state.withLock { current in
            let drained = current.buffer
            current.buffer.removeAll()
            current.finished = true
            return drained
        }
        if !strays.isEmpty {
            throw AsyncProbeError.unexpectedElements(
                count: strays.count,
                debugDescription: String(describing: strays)
            )
        }
    }

    private enum NextOutcome { case deliver(Element), finished, queued, cancelled }
}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
public enum AsyncProbeError: Error, Sendable, CustomStringConvertible {
    case unexpectedElements(count: Int, debugDescription: String)

    public var description: String {
        switch self {
            case .unexpectedElements(let count, let debugDescription):
                "AsyncProbe expected an empty buffer but found \(count) element(s): \(debugDescription)"
        }
    }
}

import Foundation
import Synchronization

/// Typed counter + collector that lets a test wait until a known event boundary has fired
/// `N` times, then introspect what was recorded.
///
/// `CountProbe` replaces ad-hoc counters and `Task.yield()` polling loops in tests. The
/// system-under-test (or a test double) calls ``record(_:)`` whenever an observable effect
/// happens; the test awaits that boundary with ``wait(forAtLeast:timeout:)`` and then asserts
/// on ``events`` / ``count`` / ``isEmpty``.
///
/// ## Canonical usage
///
/// Wire ``record(_:)`` to the SUT's observable effect, start the work, await the boundary,
/// then assert. No `withThrowingTaskGroup`, no manual timeout task, no `group.next()`
/// versus `group.waitForAll()` subtlety — the probe owns the deadline:
///
/// ```swift
/// let probe = CountProbe<Int>()
/// let producer = NumberStreamer(onEmit: { probe.record($0) })
///
/// producer.start(emitting: [1, 2, 3])   // fire-and-forget async work
/// try await probe.wait(forAtLeast: 3)   // suspends until the 3rd event — or the deadline
///
/// #expect(probe.events == [1, 2, 3])
/// ```
///
/// ## Count-only probes
///
/// When a test only cares *how many* times a boundary fired — not the payloads — construct a bare
/// `CountProbe()` and use the no-argument ``record()`` overload. With no generic argument the
/// payload type resolves to the uninhabited `Never` (see ``init(label:file:function:line:)``), so
/// no `<Never>` is spelled at the call site, the payload-taking ``record(_:)`` cannot be called
/// (there is no `Never` to pass), and ``events`` is provably always empty — count-only is a
/// type-level guarantee and the backing array never grows:
///
/// ```swift
/// let spawns = CountProbe()              // no generic argument; the payload resolves to Never
/// spawns.record()                        // the only way to record; `record(())` cannot compile
/// try await spawns.wait(forAtLeast: 1)
/// ```
///
/// ``wait(forAtLeast:timeout:)`` races the recorded-count boundary against `timeout`
/// (default 1s) internally, so a producer that never reaches the target fails *fast* with a
/// ``CountProbeTimeoutError`` pointing at the probe's creation site, instead of hanging or
/// blocking until an unrelated sibling task finishes.
///
/// ## Threading
///
/// State lives in a `Mutex<State>` (Synchronization, iOS 18+). The count and the event array are
/// updated under the same lock, so a waiter woken at count `N` always observes `N` recorded
/// events. Continuations are resumed *outside* the lock so a re-entrant resumer cannot deadlock,
/// and cancellation is checked *inside* the lock so a sleeper is never orphaned between
/// registration and the cancellation handler.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
public final class CountProbe<Event: Sendable>: Sendable {
    private struct Sleeper {
        let target: Int
        let resume: @Sendable () -> Void
    }

    private struct State {
        var count = 0
        var events: [Event] = []
        var sleepers: [UUID: Sleeper] = [:]
    }

    private let state = Mutex(State())
    private let label: String
    private let file: StaticString
    private let function: String
    private let line: UInt

    // The designated initializer is positional so the labeled convenience initializers — including
    // the count-only one in the `Event == Never` extension — delegate to it without re-resolving
    // to themselves (which would recurse).
    private init(_ label: String, _ file: StaticString, _ function: String, _ line: UInt) {
        self.label = label
        self.file = file
        self.function = function
        self.line = line
    }

    /// Creates an event probe. For a count-only probe omit the generic argument entirely —
    /// `CountProbe()` resolves to the `Event == Never` initializer.
    ///
    /// - Parameters:
    ///   - label: Optional name surfaced in ``CountProbeTimeoutError`` for easier diagnosis.
    ///   - file: Creation-site file, reported by ``CountProbeTimeoutError`` on timeout.
    ///   - function: Creation-site function, reported by ``CountProbeTimeoutError`` on timeout.
    ///   - line: Creation-site line, reported by ``CountProbeTimeoutError`` on timeout.
    public convenience init(
        label: String = "",
        file: StaticString = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        self.init(label, file, function, line)
    }

    /// Records one event. Wakes any sleeper whose target count has been reached.
    public func record(_ event: Event) {
        let resumers = state.withLock { state in
            state.events.append(event)
            return resumersAfterRecording(&state)
        }
        for resume in resumers {
            resume()
        }
    }

    /// Increments the recorded count and collects the sleepers that count now satisfies. Must run
    /// inside `state.withLock` so the count, the event array, and the sleeper set stay consistent.
    private func resumersAfterRecording(_ state: inout State) -> [@Sendable () -> Void] {
        state.count += 1
        let reached = state.count
        var triggered: [@Sendable () -> Void] = []
        state.sleepers = state.sleepers.filter { _, sleeper in
            if reached >= sleeper.target {
                triggered.append(sleeper.resume)
                return false
            }
            return true
        }
        return triggered
    }

    /// Suspends until at least `count` events have been recorded, or `timeout` elapses.
    ///
    /// The probe races the recorded-count boundary against `timeout` internally, so callers
    /// neither spawn a timeout task nor coordinate a task group: a producer that never reaches
    /// the target surfaces as a fast, diagnostic failure rather than a hang. See the type-level
    /// documentation for the canonical drive → wait → assert pattern.
    ///
    /// - Parameters:
    ///   - count: The number of recorded events to wait for.
    ///   - timeout: How long to wait before giving up. Defaults to 1 second.
    /// - Throws: ``CountProbeTimeoutError`` — reporting the probe's creation site — if `timeout`
    ///   elapses first, or `CancellationError` if the awaiting task is cancelled.
    public func wait(
        forAtLeast count: Int,
        timeout: Duration = .seconds(1)
    ) async throws {
        try Task.checkCancellation()
        if state.withLock({ $0.count >= count }) { return }

        let id = UUID()
        let outcome = await raceSleeperAgainstTimeout(id: id, target: count, timeout: timeout)
        _ = state.withLock { $0.sleepers.removeValue(forKey: id) }

        switch outcome {
            case .satisfied:
                return
            case .timedOut:
                throw timeoutError(expected: count)
            case .cancelled:
                throw CancellationError()
        }
    }

    /// Captures diagnostic state consistently for a wait that has expired.
    func timeoutError(expected count: Int) -> CountProbeTimeoutError<Event> {
        state.withLock { state in
            CountProbeTimeoutError(
                label: label, expected: count, recordedCount: state.count, recorded: state.events,
                file: file, function: function, line: line)
        }
    }

    private func raceSleeperAgainstTimeout(
        id: UUID,
        target: Int,
        timeout: Duration
    ) async -> Outcome {
        await withTaskGroup(of: Outcome.self) { group in
            group.addTask { [self] in
                await sleepUntilTarget(id: id, target: target)
                // The sleeper continuation can be resumed either by `record` crossing the target
                // or by `onCancel` removing the registration after a cancellation. Inspecting
                // `Task.isCancelled` here disambiguates the two so a cancellation does not
                // masquerade as a satisfied wait.
                return Task.isCancelled ? .cancelled : .satisfied
            }
            group.addTask {
                do {
                    try await Task.sleep(for: timeout)
                    return .timedOut
                } catch {
                    return .cancelled
                }
            }
            let first = await group.next() ?? .cancelled
            group.cancelAll()
            return first
        }
    }

    private func sleepUntilTarget(id: UUID, target: Int) async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                // Inspecting `Task.isCancelled` inside the lock closes the race where cancellation
                // could land between the `withTaskCancellationHandler` registration and the
                // sleeper insertion: in that window `onCancel` would not see a sleeper to remove
                // and the continuation would hang. By short-circuiting under the lock we either
                // skip registration entirely (and resume immediately) or know that the sleeper is
                // safely registered before `onCancel` could run.
                let shouldResumeImmediately = state.withLock { state in
                    if Task.isCancelled || state.count >= target {
                        return true
                    }
                    state.sleepers[id] = Sleeper(
                        target: target,
                        resume: { continuation.resume() }
                    )
                    return false
                }
                if shouldResumeImmediately {
                    continuation.resume()
                }
            }
        } onCancel: {
            let leftover = state.withLock { $0.sleepers.removeValue(forKey: id) }
            leftover?.resume()
        }
    }

    /// Snapshot of all events recorded so far. Always empty for a count-only `CountProbe<Never>`.
    public var events: [Event] {
        state.withLock { $0.events }
    }

    /// `true` when nothing has been recorded yet — accurate for both event and count-only probes
    /// (a count-only `CountProbe<Never>` never stores events, so this tracks ``count``, not the
    /// backing array).
    public var isEmpty: Bool {
        state.withLock { $0.count == 0 }
    }

    /// Number of times the probe has recorded, whether or not a payload was stored.
    public var count: Int {
        state.withLock { $0.count }
    }

    private enum Outcome {
        case satisfied
        case timedOut
        case cancelled
    }
}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
extension CountProbe where Event == Never {
    /// Creates a count-only probe. Constraining the payload to `Never` is what lets a bare
    /// `CountProbe()` — with no generic argument — resolve here: when the payload is not otherwise
    /// pinned, this is the only applicable initializer. Event probes still spell their payload, as
    /// in `CountProbe<Int>()`.
    public convenience init(
        label: String = "",
        file: StaticString = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        self.init(label, file, function, line)
    }

    /// Records one occurrence for a count-only probe. Wakes any sleeper whose target count has
    /// been reached. A count-only probe has no callable payload-taking `record(_:)` (you cannot
    /// construct a `Never`), so this is the only way to record and the backing array stays empty.
    public func record() {
        let resumers = state.withLock { state in resumersAfterRecording(&state) }
        for resume in resumers {
            resume()
        }
    }
}

// MARK: - Error

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
public struct CountProbeTimeoutError<Event: Sendable>: Error, Sendable, CustomStringConvertible {
    public let label: String
    public let expected: Int
    public let recordedCount: Int
    public let recorded: [Event]
    public let file: StaticString
    public let function: String
    public let line: UInt

    public var description: String {
        let prefix = label.isEmpty ? "CountProbe" : "CountProbe '\(label)'"
        let payload = recorded.isEmpty ? "" : ": \(recorded)"
        return "\(prefix) timed out at \(file):\(line) (\(function)); "
            + "expected at least \(expected), recorded \(recordedCount)\(payload)"
    }
}

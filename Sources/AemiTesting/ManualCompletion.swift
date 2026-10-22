import Synchronization

/// Suspends requests until a test supplies each response, in any order.
///
/// Inject ``receive()`` into a service double and `await` ``requests`` before completing a request:
///
/// ```swift
/// let completion = ManualCompletion<Profile>()
/// let service = FakeProfileService(fetch: { try await completion.receive() })
/// subject.refresh()                           // request 0
/// subject.refresh()                           // request 1
/// try await completion.requests.wait(forAtLeast: 2)
/// try completion.complete(at: 1, returning: newer)
/// try completion.complete(at: 0, returning: older)   // arrives late
/// ```
///
/// That order — request 1 before request 0 — is the point: it verifies that an older response cannot
/// overwrite newer state, without sleeps or scheduler assumptions.
///
/// Requests are numbered from 0 in the order ``receive()`` is called.
///
/// ## Cancellation
///
/// Cancelling the task that called ``receive()`` deliberately leaves its request pending: a cancelled service
/// may still return a result, and the caller must reject it. A test must therefore complete every registered
/// request, cancelled ones included, so their callers can finish. ``pendingCount`` shows what is outstanding.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
public final class ManualCompletion<Value: Sendable>: Sendable {
    /// Why a request could not be completed.
    public enum CompletionError: Swift.Error, Equatable {
        case requestNotFound(reason: Reason)

        public enum Reason: Sendable, Equatable {
            /// No request has that number (yet).
            case indexNotFound
            /// The request was completed before.
            case alreadyCompleted
        }
    }

    private struct State {
        var pending: [Int: CheckedContinuation<Value, any Error>] = [:]
        var nextIndex = 0
    }

    /// Records once per ``receive()`` call, after the request is registered. A test awaits
    /// `requests.wait(forAtLeast:)` before completing a request.
    public let requests = CountProbe()

    private let state = Mutex(State())

    public init() {}

    /// How many requests are waiting to be completed.
    public var pendingCount: Int { state.withLock { $0.pending.count } }

    /// Registers a request and suspends until the test completes it.
    public func receive() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            state.withLock { state in
                state.pending[state.nextIndex] = continuation
                state.nextIndex += 1
            }
            requests.record()
        }
    }

    /// Completes request `index` with `result`, resuming its caller.
    ///
    /// - Throws: ``CompletionError/requestNotFound(reason:)`` if no request has that number or it was
    ///   completed already.
    public func complete(at index: Int, with result: Result<Value, any Error>) throws(CompletionError) {
        let outcome = state.withLock { state -> Result<CheckedContinuation<Value, any Error>, CompletionError> in
            if let continuation = state.pending.removeValue(forKey: index) { return .success(continuation) }
            let wasRegistered = index >= 0 && index < state.nextIndex
            return .failure(.requestNotFound(reason: wasRegistered ? .alreadyCompleted : .indexNotFound))
        }
        switch outcome {
            case .success(let continuation): continuation.resume(with: result)
            case .failure(let error): throw error
        }
    }

    /// Completes request `index` with `value`.
    public func complete(at index: Int, returning value: Value) throws(CompletionError) {
        try complete(at: index, with: .success(value))
    }

    /// Completes request `index` by throwing `error` from ``receive()``.
    public func complete(at index: Int, throwing error: any Swift.Error) throws(CompletionError) {
        try complete(at: index, with: .failure(error))
    }
}

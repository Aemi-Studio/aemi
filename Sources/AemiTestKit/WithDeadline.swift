/// Runs `operation` against a deadline: what it returns, or `nil` once `timeout` has passed on `clock`.
///
/// For an answer that may never come — the next element of a stream, a reply, a task's end — where the test goes on
/// either way (a miss is counted or asserted). The operation and the deadline race in a task group; the loser is
/// cancelled, so the operation must end when cancelled. The deadline's sleep is the harness's: on a ``TestClock`` it is
/// untracked (``TestClock/withUntrackedSleeps(_:)``), so it is not among the sleepers a test waits for.
///
/// ```swift
/// let next = await withDeadline(within: .seconds(2)) { await iterator.next() }
/// ```
///
/// - Parameters:
///   - timeout: How long the operation has, on `clock`.
///   - clock: The clock the deadline runs on.
///   - operation: The work that may not end.
/// - Returns: What `operation` returned, or `nil` if the deadline came first.
/// - Throws: What `operation` throws, if it throws before the deadline.
public func withDeadline<Value: Sendable, C: Clock>(
    within timeout: C.Duration,
    clock: C,
    _ operation: @escaping @Sendable () async throws -> Value
) async rethrows -> Value? {
    try await withThrowingTaskGroup(of: Value?.self) { group in
        group.addTask { try await operation() }
        TestClock.withUntrackedSleeps {
            group.addTask {
                try? await clock.sleep(for: timeout)
                return nil
            }
        }
        defer { group.cancelAll() }
        return try await group.next() ?? nil
    }
}

/// ``withDeadline(within:clock:_:)`` on a `ContinuousClock`.
public func withDeadline<Value: Sendable>(
    within timeout: Duration,
    _ operation: @escaping @Sendable () async throws -> Value
) async rethrows -> Value? {
    try await withDeadline(within: timeout, clock: ContinuousClock(), operation)
}

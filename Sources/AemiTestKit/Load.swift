// `public import`: the load asserts expose Swift Testing's `SourceLocation` publicly.
public import Testing

/// A `Sendable` snapshot of a worker's thrown error. A concurrent worker's concrete `any Error` is not
/// `Sendable` (so it cannot cross the task-group boundary as-is); its dynamic type name + description are
/// captured here for the assertion site — enough to assert on the failure shape without the live value.
public struct LoadError: Error, Sendable, CustomStringConvertible {
    public let typeName: String
    public let description: String
    init(_ error: any Error) {
        typeName = String(reflecting: type(of: error))
        description = String(describing: error)
    }
    init(typeName: String, description: String) {
        self.typeName = typeName
        self.description = description
    }
}

/// The outcome of a concurrent-load run: every worker's `Result` (in worker order) plus rolled-up
/// counts. `complete` is false when the deadline elapsed before all workers settled (the run also
/// records an `Issue` in that case — the assertion never hangs).
public struct LoadOutcome<R: Sendable>: Sendable {
    /// One entry per worker, indexed by worker id. A worker that never settled before the deadline is a
    /// `.failure(LoadError)` with `typeName` `LoadWorkerTimedOut`.
    public let results: [Result<R, LoadError>]
    /// Every worker settled before the deadline.
    public let complete: Bool

    public init(results: [Result<R, LoadError>], complete: Bool) {
        self.results = results
        self.complete = complete
    }

    /// The successful return values, in worker order.
    public var successes: [R] { results.compactMap { try? $0.get() } }
    public var successCount: Int { results.reduce(into: 0) { if case .success = $1 { $0 += 1 } } }
    public var failureCount: Int { results.count - successCount }
}

/// Marks a worker that did not settle before the run's deadline.
public struct LoadWorkerTimedOut: Error, Sendable {}

/// One task-group event in `expectAllConcurrent` — a settled worker, the herd release, or the deadline.
/// File-scope (not nested) because a generic type cannot be nested in a generic function.
private enum LoadEvent<R: Sendable>: Sendable {
    case work(Int, Result<R, LoadError>)
    case released
    case deadline
}

/// Runs `count` copies of `body` CONCURRENTLY and returns every worker's `Result` once all settle, or
/// once the `within` deadline elapses (a straggler is recorded as an `Issue` and marked timed-out —
/// never a hang). When `thunderingHerd` is true (default) every worker parks on a shared gate and all
/// are released together once the last has parked, maximizing simultaneous contention on whatever shared
/// state `body` touches — the right shape for race-detection / admission-control under load. The herd
/// release is probe-gated (deterministic), not timed. Built on `AsyncGate` + `AsyncEventProbe`; no sleeps
/// on the happy path.
@discardableResult
public func expectAllConcurrent<R: Sendable>(
    count: Int,
    within: Duration = .seconds(5),
    thunderingHerd: Bool = true,
    sourceLocation: SourceLocation = #_sourceLocation,
    perform body: @Sendable @escaping (_ worker: Int) async throws -> R
) async -> LoadOutcome<R> {
    guard count > 0 else { return LoadOutcome(results: [], complete: true) }
    let gate = AsyncGate()
    let parked = AsyncEventProbe<Void>()

    return await withTaskGroup(of: LoadEvent<R>.self) { group in
        for worker in 0 ..< count {
            group.addTask {
                if thunderingHerd {
                    parked.record(())
                    try? await gate.waitUntilOpen()
                }
                do { return .work(worker, .success(try await body(worker))) } catch {
                    return .work(worker, .failure(LoadError(error)))
                }
            }
        }
        if thunderingHerd {
            // Release ONLY once every worker has parked → a true simultaneous start (deterministic,
            // probe-gated). If they never all park within the deadline, release whoever did so the
            // group can still drain.
            group.addTask {
                _ = try? await parked.wait(forAtLeast: count, timeout: within)
                for _ in 0 ..< count { gate.open() }
                return .released
            }
        }
        group.addTask {
            try? await Task.sleep(for: within)
            return .deadline
        }

        var slots = [Result<R, LoadError>?](repeating: nil, count: count)
        var settled = 0
        var complete = false
        loop: while let event = await group.next() {
            switch event {
                case .work(let worker, let result):
                    slots[worker] = result
                    settled += 1
                    if settled == count {
                        complete = true
                        break loop
                    }
                case .released:
                    continue
                case .deadline:
                    break loop
            }
        }
        group.cancelAll()
        if !complete {
            Issue.record(
                "expectAllConcurrent: only \(settled)/\(count) workers settled within \(within)",
                sourceLocation: sourceLocation)
        }
        let timeout = LoadError(LoadWorkerTimedOut())
        return LoadOutcome(results: slots.map { $0 ?? .failure(timeout) }, complete: complete)
    }
}

/// Admission-control assertion: run `count` concurrent workers and assert EXACTLY `k` of them succeed
/// (the rest throw) — e.g. a connection/SSE limiter admits `k` and rejects the overflow, a rate limiter
/// passes `k` within the window. Records an `Issue` when the success count differs from `k`; returns the
/// full `LoadOutcome` for further inspection.
@discardableResult
public func expectExactlyKSucceed<R: Sendable>(
    of count: Int,
    succeed k: Int,
    within: Duration = .seconds(5),
    thunderingHerd: Bool = true,
    sourceLocation: SourceLocation = #_sourceLocation,
    perform body: @Sendable @escaping (_ worker: Int) async throws -> R
) async -> LoadOutcome<R> {
    let outcome = await expectAllConcurrent(
        count: count, within: within, thunderingHerd: thunderingHerd, sourceLocation: sourceLocation,
        perform: body)
    if outcome.successCount != k {
        Issue.record(
            "expected exactly \(k) of \(count) workers to succeed, got \(outcome.successCount)",
            sourceLocation: sourceLocation)
    }
    return outcome
}

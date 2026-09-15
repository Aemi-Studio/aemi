import Dispatch
import Foundation  // Thread.sleep
import Synchronization
import Testing

@testable import AemiRuntime

/// A test-local error used to turn a HANG (a lost-wakeup regression) into a clean, fast test
/// failure instead of an infinite stall: the work races a deadline task.
private struct DeadlineExceeded: Error {}

/// Run `operation`, failing with `DeadlineExceeded` if it does not finish within `milliseconds` —
/// so a lost-wakeup or never-resumed continuation surfaces as a failed assertion, not a wedged run.
private func withDeadline<T: Sendable>(
    _ milliseconds: Int, _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .milliseconds(milliseconds))
            throw DeadlineExceeded()
        }
        let first = try await group.next()!
        group.cancelAll()
        return first
    }
}

@Suite struct BlockingOffloadPoolTests {
    /// The core contract: N concurrent blocking jobs ALL complete with their exact results and the
    /// pool never wedges. A lost-wakeup (signalling under the wrong lock) or a never-resumed
    /// continuation would hang here — the deadline converts that into a failure. Full-set equality
    /// (not just count) makes a mutant that drops/duplicates a result fail.
    @Test func runsEveryConcurrentJobToCompletionWithExactResults() async throws {
        let pool = BlockingOffloadPool(width: 8)
        defer { pool.shutdown() }
        let jobs = 64
        let results = try await withDeadline(5000) {
            try await withThrowingTaskGroup(of: Int.self) { group in
                for index in 0 ..< jobs {
                    group.addTask {
                        try await pool.run {
                            // A genuine blocking call: parks THIS (pool) thread, not a cooperative one.
                            Thread.sleep(forTimeInterval: 0.003)
                            return index * 2
                        }
                    }
                }
                var collected: [Int] = []
                for try await value in group { collected.append(value) }
                return collected.sorted()
            }
        }
        #expect(results == (0 ..< jobs).map { $0 * 2 })
    }

    /// Concurrency is bounded by `width`: at most `width` jobs run at once. A mutant that ignored
    /// the bound (e.g. spawned a thread per job) would push `peak` past `width` and fail; requiring
    /// `peak >= 2` also proves the jobs genuinely overlap (it is a pool, not a serial queue).
    @Test func concurrencyNeverExceedsConfiguredWidth() async throws {
        let width = 4
        let pool = BlockingOffloadPool(width: width)
        defer { pool.shutdown() }
        let tracker = Mutex<(inFlight: Int, peak: Int)>((0, 0))
        try await withDeadline(5000) {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0 ..< 40 {
                    group.addTask { @Sendable in
                        try await pool.run {
                            tracker.withLock { state in
                                state.inFlight += 1
                                state.peak = max(state.peak, state.inFlight)
                            }
                            Thread.sleep(forTimeInterval: 0.005)
                            tracker.withLock { $0.inFlight -= 1 }
                        }
                    }
                }
                for try await () in group {}
            }
        }
        let peak = tracker.withLock { $0.peak }
        #expect(peak <= width)
        #expect(peak >= 2)
    }

    /// The body's return value is delivered, and a thrown error propagates through the bridge
    /// unchanged (exactly-once resume on BOTH the success and failure paths).
    @Test func deliversResultsAndPropagatesThrownErrors() async throws {
        struct Boom: Error, Equatable { let code: Int }
        let pool = BlockingOffloadPool(width: 2)
        defer { pool.shutdown() }

        let value = try await pool.run { 21 * 2 }
        #expect(value == 42)

        await #expect(throws: Boom(code: 7)) {
            try await pool.run { throw Boom(code: 7) }
        }
    }

    /// Cancelling a task whose job is still QUEUED (the single worker is busy) removes the job and
    /// throws `CancellationError` — without disturbing the in-flight job. Guards the cancellation
    /// path the bespoke executor lacked (a cancelled-after-dispatch leak).
    @Test func cancellingAQueuedJobThrowsCancellationError() async throws {
        let pool = BlockingOffloadPool(width: 1)
        defer { pool.shutdown() }
        let started = Atomic<Bool>(false)
        let release = DispatchSemaphore(value: 0)

        // Occupy the single worker with a gated job so the next submission must queue behind it.
        // `release.wait()` runs INSIDE the job (a pool thread), never the async test body.
        let blocker = Task {
            try await pool.run {
                started.store(true, ordering: .releasing)
                release.wait()
            }
        }
        while !started.load(ordering: .acquiring) { try await Task.sleep(for: .milliseconds(5)) }

        let queued = Task { try await pool.run { 123 } }
        try await Task.sleep(for: .milliseconds(50))  // ensure `queued` has enqueued
        queued.cancel()
        await #expect(throws: CancellationError.self) { _ = try await queued.value }

        release.signal()  // free the worker; the blocker completes normally
        try await blocker.value
    }

    /// A task ALREADY cancelled when `run` is entered must throw `CancellationError` and NOT execute
    /// its body — the pre-cancelled edge. The task parks at a long sleep (a cancellation point) until
    /// cancelled, so by the time it reaches `pool.run` it is guaranteed cancelled; the body setting
    /// `ran` would fail the `#expect` if the pre-entry check were missing (which is exactly the bug
    /// this guards: `onCancel` fires before the job is queued, so only the in-`run` check can catch it).
    @Test func alreadyCancelledTaskThrowsWithoutRunningBody() async throws {
        let pool = BlockingOffloadPool(width: 2)
        defer { pool.shutdown() }
        let ran = Atomic<Bool>(false)
        let task = Task {
            try? await Task.sleep(for: .seconds(3600))  // parks here until the cancel below fires
            return try await pool.run {
                ran.store(true, ordering: .releasing)
                return 1
            }
        }
        task.cancel()
        _ = try await withDeadline(5000) {
            await #expect(throws: CancellationError.self) { _ = try await task.value }
        }
        #expect(ran.load(ordering: .acquiring) == false)
    }

    /// After `shutdown()` the pool refuses work (`poolShuttingDown`), and a second `shutdown()` is a
    /// no-op that returns immediately — the idempotency guard prevents a double-join deadlock.
    @Test func shutdownIsIdempotentAndRefusesFurtherWork() async throws {
        let pool = BlockingOffloadPool(width: 2)
        pool.shutdown()
        pool.shutdown()  // must not hang (idempotent join)

        await #expect(throws: BlockingOffloadPool.SubmissionError.self) {
            try await pool.run { 1 }
        }
    }

    /// Usable as a native `TaskExecutor`: blocking work under `withTaskExecutorPreference` runs to
    /// completion (width-bounded) and returns its value — the "native ergonomics" path.
    @Test func runsAsATaskExecutorViaPreference() async throws {
        let pool = BlockingOffloadPool(width: 4)
        defer { pool.shutdown() }
        let sum = try await withDeadline(5000) {
            await withTaskGroup(of: Int.self) { group in
                for index in 0 ..< 16 {
                    group.addTask {
                        await withTaskExecutorPreference(pool) {
                            // Real (sync) work on the pool thread — Thread.sleep is unavailable in an
                            // async operation closure, so a small CPU spin is the stand-in.
                            var spin = 0
                            for value in 1 ... 1000 { spin &+= value }
                            return spin == 500_500 ? index : -1
                        }
                    }
                }
                var total = 0
                for await value in group { total += value }
                return total
            }
        }
        #expect(sum == (0 ..< 16).reduce(0, +))
    }
}

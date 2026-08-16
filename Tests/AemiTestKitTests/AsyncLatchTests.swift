import Testing

@testable import AemiTestKit

/// Coverage for the broadcast latch. The cases that matter are the ones that distinguish it from
/// ``AsyncGate`` (release-all vs release-one, idempotent open vs banked permits) plus the
/// cancellation contract shared by every parking primitive in the kit.
///
/// The waiting tests carry a `.timeLimit`: every failure mode here is "a waiter is never resumed",
/// which without a deadline is an indefinite hang rather than a diagnosable failure. Verified —
/// degrading `open()` to release a single waiter hangs the suite unless the limit is present.
@Suite(.tags(.concurrency))
struct AsyncLatchTests {
    @Test(.timeLimit(.minutes(1)))
    func `an initially-open latch never suspends`() async throws {
        let latch = AsyncLatch(initiallyOpen: true)
        #expect(latch.isOpen)
        try await latch.wait()
        try await latch.wait()  // still open — repeatable
        #expect(latch.waiterCount == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func `open releases every waiter, not just one`() async throws {
        let latch = AsyncLatch()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 4 {
                group.addTask { try await latch.wait() }
            }
            while latch.waiterCount < 4 {
                await Task.yield()
            }

            latch.open()  // one call, all four proceed — the AsyncGate contrast
            try await group.waitForAll()
        }
        #expect(latch.waiterCount == 0)
        #expect(latch.isOpen)
    }

    @Test(.timeLimit(.minutes(1)))
    func `a wait after open returns without suspending`() async throws {
        let latch = AsyncLatch()
        latch.open()
        try await latch.wait()
        #expect(latch.waiterCount == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func `open is idempotent`() async throws {
        let latch = AsyncLatch()
        latch.open()
        latch.open()  // must be a no-op, not a trap or a second broadcast
        latch.open()
        try await latch.wait()
        #expect(latch.isOpen)
    }

    @Test(.timeLimit(.minutes(1)))
    func `a cancelled waiter throws and unregisters`() async throws {
        let latch = AsyncLatch()
        let waiter = Task { try await latch.wait() }
        while latch.waiterCount < 1 {
            await Task.yield()
        }

        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(latch.waiterCount == 0)  // unregistered, not leaked
        #expect(!latch.isOpen)  // cancelling a waiter must not open the latch
    }

    @Test(.timeLimit(.minutes(1)))
    func `cancelling one waiter leaves the others to be released`() async throws {
        let latch = AsyncLatch()
        let doomed = Task { try await latch.wait() }
        let survivor = Task { try await latch.wait() }
        while latch.waiterCount < 2 {
            await Task.yield()
        }

        doomed.cancel()
        await #expect(throws: CancellationError.self) { try await doomed.value }
        #expect(latch.waiterCount == 1)

        latch.open()
        try await survivor.value  // resumes normally; the stale slot is skipped
        #expect(latch.waiterCount == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func `waiting on an already-cancelled task throws before parking`() async {
        let latch = AsyncLatch()
        let waiter = Task {
            // Cancel before the first suspension point so `wait()` takes its pre-park check.
            while !Task.isCancelled {
                await Task.yield()
            }
            try await latch.wait()
        }
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(latch.waiterCount == 0)
    }
}

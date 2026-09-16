import AemiTestKit
import Testing

@testable import AemiRuntime

/// `mapConcurrently` regression coverage. Every transform parks on a latch the test opens, so
/// completion order and the number of transforms in flight are driven by the test, never by
/// scheduling luck or a sleep.
@Suite(.tags(.concurrency))
struct ConcurrentMapTests {
    @Test(.timeLimit(.minutes(1)))
    func `results keep the input order whatever the completion order`() async throws {
        let latches = (0 ..< 8).map { _ in AsyncLatch() }
        let started = AsyncEventProbe<Int>()
        async let results = mapConcurrently(Array(0 ..< 8), limit: 8) { value in
            started.record(value)
            try await latches[value].wait()
            return value * 2
        }
        _ = try await started.wait(forAtLeast: 8)
        // Release in reverse, so the last item completes first.
        for latch in latches.reversed() {
            latch.open()
        }
        let ordered = try await results
        #expect(ordered == (0 ..< 8).map { $0 * 2 })
    }

    @Test(.timeLimit(.minutes(1)))
    func `never more than the limit runs at once`() async throws {
        let latches = (0 ..< 5).map { _ in AsyncLatch() }
        let started = AsyncEventProbe<Int>()
        async let results = mapConcurrently(Array(0 ..< 5), limit: 2) { value in
            started.record(value)
            try await latches[value].wait()
            return value
        }
        // Two transforms are parked; a third cannot start until one of them finishes.
        _ = try await started.wait(forAtLeast: 2)
        #expect(Set(started.events) == [0, 1])
        latches[0].open()
        _ = try await started.wait(forAtLeast: 3)
        #expect(Set(started.events) == [0, 1, 2])
        latches[1].open()
        _ = try await started.wait(forAtLeast: 4)
        #expect(Set(started.events) == [0, 1, 2, 3])
        for latch in latches {
            latch.open()
        }
        let all = try await results
        #expect(all == [0, 1, 2, 3, 4])
    }

    @Test(.timeLimit(.minutes(1)))
    func `an error stops the whole map and cancels the transforms in flight`() async throws {
        struct Failure: Error {}
        let neverOpened = AsyncLatch()
        let cancelled = AsyncEventProbe<Int>()
        let started = AsyncEventProbe<Int>()
        let map = Task {
            try await mapConcurrently([1, 2, 3], limit: 2) { value in
                started.record(value)
                if value == 2 { throw Failure() }
                do {
                    try await neverOpened.wait()
                } catch is CancellationError {
                    cancelled.record(value)
                    throw CancellationError()
                }
                return value
            }
        }
        await #expect(throws: Failure.self) { try await map.value }
        // The transform for 1 was parked on the latch and only leaves through cancellation.
        _ = try await cancelled.wait(forAtLeast: 1)
        #expect(cancelled.events == [1])
        #expect(!started.events.contains(3))
    }

    @Test
    func `an empty input yields an empty result`() async throws {
        let results: [Int] = try await mapConcurrently([Int](), limit: 3) { $0 }
        #expect(results.isEmpty)
    }

    @Test
    func `a limit below one behaves as one`() async throws {
        let results = try await mapConcurrently([1, 2, 3], limit: 0) { $0 + 1 }
        #expect(results == [2, 3, 4])
    }
}

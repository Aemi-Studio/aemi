import AemiTestKit
import Synchronization
import Testing

@Suite("waitUntil") struct WaitUntilTests {
    @Test func `ends at the first look that holds`() async throws {
        let looks = Mutex(0)
        try await waitUntil {
            looks.withLock {
                $0 += 1
                return $0 == 3
            }
        }
        #expect(looks.withLock { $0 } == 3)
    }

    @Test func `holding at once, it does not wait`() async throws {
        let clock = TestClock()
        try await waitUntil(within: .seconds(1), every: .seconds(1), clock: clock) { true }
        #expect(clock.now == TestClock.Instant(offset: .zero))
    }

    @Test func `times out at the call site, naming the wait and counting the looks`() async throws {
        let error = try #require(
            await #expect(throws: AsyncEventProbeTimeoutError.self) {
                try await waitUntil(timeout: .milliseconds(20), label: "never") { false }
            }
        )
        #expect(error.label == "never" && error.isPredicateWait && error.recorded > 1)
        #expect(error.creation.fileID.hasSuffix("WaitUntilTests.swift"))
    }

    @Test func `on a test clock, looks again only when the clock moves, and the deadline is the clock's`() async throws
    {
        let clock = TestClock()
        let looks = Mutex(0)
        let polling = Task {
            try await waitUntil(within: .seconds(1), every: .milliseconds(100), clock: clock) {
                looks.withLock {
                    $0 += 1
                    return false
                }
            }
        }
        var mark = clock.registrationMark()
        for expected in 1 ... 3 {
            try await clock.waitForSleepers(1, after: mark)
            #expect(looks.withLock { $0 } == expected)
            mark = clock.registrationMark()
            clock.advance(by: .milliseconds(100))
        }
        try await clock.waitForSleepers(1, after: mark)
        clock.advance(by: .seconds(1))
        await #expect(throws: AsyncEventProbeTimeoutError.self) { try await polling.value }
    }

    @Test func `a condition that throws ends the wait with its error`() async throws {
        struct Broken: Error {}
        await #expect(throws: Broken.self) { try await waitUntil { throw Broken() } }
    }
}

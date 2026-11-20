import AemiTestKit
import Testing

@Suite("withDeadline") struct WithDeadlineTests {
    @Test func `the answer when it comes first`() async throws {
        #expect(await withDeadline(within: .seconds(30)) { 42 } == 42)
    }

    @Test func `nil when the deadline does, and the operation is cancelled`() async throws {
        let clock = TestClock()
        let latch = AsyncLatch()
        let cancelled = AsyncEventProbe()
        let racing = Task {
            await withDeadline(within: .seconds(1), clock: clock) {
                do { try await latch.wait() } catch { cancelled.record() }
                return 1
            }
        }
        try await clock.waitForUntrackedSleepers(atLeast: 1)
        #expect(clock.sleeperCount == 0, "the deadline is the harness's sleep, not one a test waits for")
        clock.advance(by: .seconds(1))
        #expect(await racing.value == nil)
        try await cancelled.wait(forAtLeast: 1)
    }

    @Test func `an error thrown before the deadline is rethrown`() async throws {
        struct Broken: Error {}
        await #expect(throws: Broken.self) {
            _ = try await withDeadline(within: .seconds(30)) { () async throws -> Int in throw Broken() }
        }
    }
}

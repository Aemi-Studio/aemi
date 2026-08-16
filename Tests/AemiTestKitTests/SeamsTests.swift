import AemiTestKitSeams
import Testing

@testable import AemiTestKit

/// Coverage for the shipped-safe `AemiTestKitSeams` surface — the live `Clock` defaults
/// and the live `TaskProvider` — which the rest of the suite never exercised because it
/// always injects the test doubles (`TestClock`, `TaskProviderSpy`).
struct SeamsTests {
    @Test
    func `LiveClock.epochSeconds returns a plausible wall-clock time`() {
        // After 2023-11-14; a sanity floor that proves we read the real clock.
        #expect(LiveClock.epochSeconds() > 1_700_000_000)
    }

    @Test
    func `LiveClock.monotonicNanoseconds is non-decreasing`() {
        let first = LiveClock.monotonicNanoseconds()
        let second = LiveClock.monotonicNanoseconds()
        #expect(second >= first)
    }

    @Test
    func `LiveTaskProvider runs a non-throwing operation like Task.init`() async throws {
        let probe = AsyncEventProbe<Int>()
        LiveTaskProvider().task { probe.record(42) }
        let events = try await probe.wait(forAtLeast: 1, timeout: .seconds(2))
        #expect(events == [42])
    }

    @Test
    func `LiveTaskProvider surfaces a throwing operation's value`() async throws {
        let handle = LiveTaskProvider().task { () async throws -> Int in 7 }
        let value = try await handle.value
        #expect(value == 7)
    }

    @Test
    func `LiveTaskProvider ignores role (only the spy reads it)`() async throws {
        let probe = AsyncEventProbe<Int>()
        LiveTaskProvider().task(role: .observation) { probe.record(1) }
        let events = try await probe.wait(forAtLeast: 1, timeout: .seconds(2))
        #expect(events == [1])
    }
}

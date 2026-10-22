import AemiMetrics
import Testing

struct RateTests {
    @Test
    func `every round runs and the rate is positive`() async {
        var rounds = 0
        let rate = await measureRate(units: 10, rounds: 3) { rounds += 1 }
        #expect(rounds == 3)
        #expect(rate.perSecond > 0)
    }

    @Test
    func `the best round of a rate is the fastest one`() async {
        // Round 1 is slow, the rest are not: the rate must reflect the fast ones.
        var round = 0
        let rate = await measureRate(units: 1, rounds: 4) {
            round += 1
            if round == 1 { spin(for: 50_000_000) }
        }
        #expect(rate.perSecond > 1 / 0.05, "the 50 ms round did not set the rate")
    }

    @Test
    func `a failing body ends the measurement and rethrows`() async {
        struct Failure: Error {}
        await #expect(throws: Failure.self) {
            _ = try await measureRate(units: 1, rounds: 2) { throw Failure() }
        }
    }

    private func spin(for nanoseconds: UInt64) {
        let start = ProcessProbe.monotonicNanos()
        while ProcessProbe.monotonicNanos() - start < nanoseconds {}
    }
}

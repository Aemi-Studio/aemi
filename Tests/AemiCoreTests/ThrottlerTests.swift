import AemiCore
import Testing

@Suite("Throttler")
struct ThrottlerTests {
    /// Each call chains a task onto the previous one and keeps only the new tail, so once a caller drops
    /// the job it was given, the tail's task is the only owner of its predecessor. Reading a freed
    /// predecessor traps, which is why this runs in a child process.
    @Test func `calls whose jobs are dropped run to completion`() async {
        await #expect(processExitsWith: .success) {
            let throttler = Throttler<Void, Never>(interval: 0)
            for _ in 0 ..< 1_000 {
                let job = await throttler {}
                _ = await job?.value()
            }
        }
    }
}

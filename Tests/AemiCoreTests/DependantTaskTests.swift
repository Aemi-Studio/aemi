import AemiCore
import Testing

@Suite("DependantTask")
struct DependantTaskTests {
    /// A task's work waits on its predecessor, so it must keep that predecessor alive: once the caller
    /// drops it, nothing else does (a predecessor links to its successor, not back, and `Throttler`
    /// swaps its reference for the new tail). Reading a freed predecessor traps, which is why this runs
    /// in a child process. Each round drops a predecessor the moment its successor is created.
    @Test func `a task keeps a predecessor nobody else holds alive`() async {
        await #expect(processExitsWith: .success) {
            for _ in 0 ..< 1_000 {
                let task = DependantTask(previous: DependantTask(), operation: {})
                _ = await task.value()
            }
        }
    }
}

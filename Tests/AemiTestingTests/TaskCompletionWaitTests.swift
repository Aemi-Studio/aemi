import Synchronization
import Testing

@testable import AemiTesting

@Test(arguments: [true, false])
func `deadline checks distinguish completed respawns from pending work`(finishes: Bool) async throws {
    let spawned = CountProbe()
    let completed = CountProbe()
    let reads = Mutex(0)
    let start = ContinuousClock.now
    spawned.record()
    let now: @Sendable () -> ContinuousClock.Instant = {
        let read = reads.withLock { value in
            value += 1
            return value
        }
        if read == 2 {
            // Work advances after the waiter snapshots its target, before it resumes.
            spawned.record()
            completed.record()
            if finishes { completed.record() }
        }
        return read == 1 ? start : start.advanced(by: .seconds(2))
    }
    if finishes {
        try await TaskCompletionWait.wait(spawned: spawned, completed: completed, timeout: .seconds(1), now: now)
        #expect(completed.count == spawned.count)
    } else {
        await #expect(throws: CountProbeTimeoutError<Never>.self) {
            try await TaskCompletionWait.wait(spawned: spawned, completed: completed, timeout: .seconds(1), now: now)
        }
    }
}

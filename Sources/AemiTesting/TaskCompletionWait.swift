/// Shares deadline and respawn tracking between work and observation waits.
enum TaskCompletionWait {
    static func wait(
        spawned: CountProbe<Never>, completed: CountProbe<Never>, timeout: Duration,
        now: @Sendable () -> ContinuousClock.Instant = { .now }
    ) async throws {
        // The safety deadline uses real time even when production uses a virtual clock.
        let deadline = now().advanced(by: timeout)
        while true {
            let target = spawned.count
            let remaining = max(.zero, now().duration(to: deadline))
            try await completed.wait(forAtLeast: target, timeout: remaining)
            // A completed respawn chain can settle while this waiter is descheduled.
            // Read completions first so a later spawn cannot be mistaken for finished work.
            if completed.count >= spawned.count { return }
            guard now() < deadline else {
                throw completed.timeoutError(expected: spawned.count)
            }
        }
    }
}

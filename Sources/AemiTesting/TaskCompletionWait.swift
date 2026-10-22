/// Shares deadline and respawn tracking between work and observation waits.
enum TaskCompletionWait {
    /// Waits until everything `spawned` counted has been counted by `completed`, including what is spawned while
    /// waiting, racing one global budget of `duration` read from `now`.
    static func wait<C: Clock>(
        spawned: CountProbe<Never>, completed: CountProbe<Never>, within duration: C.Duration, clock: C,
        now: @Sendable () -> C.Instant
    ) async throws {
        let deadline = now().advanced(by: duration)
        while true {
            let target = spawned.count
            let remaining = max(.zero, now().duration(to: deadline))
            try await completed.wait(forAtLeast: target, within: remaining, clock: clock)
            // A completed respawn chain can settle while this waiter is descheduled.
            // Read completions first so a later spawn cannot be mistaken for finished work.
            if completed.count >= spawned.count { return }
            guard now() < deadline else {
                throw completed.timeoutError(expected: spawned.count)
            }
        }
    }

    /// The same wait on `clock`, reading its time from the clock.
    static func wait<C: Clock>(
        spawned: CountProbe<Never>, completed: CountProbe<Never>, within duration: C.Duration, clock: C
    ) async throws {
        try await wait(
            spawned: spawned, completed: completed, within: duration, clock: clock, now: { clock.now })
    }

    /// The same wait on real time. The safety deadline uses real time even when production uses a virtual clock.
    static func wait(
        spawned: CountProbe<Never>, completed: CountProbe<Never>, timeout: Duration,
        now: @Sendable () -> ContinuousClock.Instant = { .now }
    ) async throws {
        try await wait(
            spawned: spawned, completed: completed, within: timeout, clock: ContinuousClock(), now: now)
    }
}

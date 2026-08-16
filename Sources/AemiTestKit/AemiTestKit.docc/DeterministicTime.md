# Deterministic time & event boundaries

Pin the clock and suspend until work happens, so time-dependent tests run in
milliseconds and never flake.

## The problem

Time-dependent code — relative-time SQL (`datetime('now', '-7 days')`), durability commit
timeouts, server-timing windows, retry backoff — is some of the hardest to test. The
naive approach sprinkles `Task.sleep` and real deadlines through the suite, which buys
three problems at once:

- **Slowness.** A test that "waits two seconds for the timeout to fire" costs two seconds,
  every run. A few hundred of those and the suite is unusable.
- **Flakiness.** On a loaded CI box a "100 ms" wait can land at 250 ms, so the assertion
  that "it hadn't fired yet" fails intermittently — the worst kind of red.
- **Non-determinism.** Whether the sleeper or the checker runs first depends on the
  scheduler, so the test passes on your laptop and fails in CI.

## The design

``TestClock`` conforms to the standard `Clock` protocol but its hands move **only when a
test calls** ``TestClock/advance(by:)``. A task that `await`s ``TestClock/sleep(until:tolerance:)``
parks until the test advances time past its deadline — consuming *zero* real time. This
generalizes the AD-family's earlier hand-rolled `ManualClock`, unifying its lock on
`Synchronization.Mutex` and adding ``TestClock/sleeperCount`` so a test can wait for a
sleeper to *register* before advancing, instead of guessing with a bare `Task.yield()`.

``AsyncEventProbe`` is the complementary "wait until something happened" boundary:
production code calls ``AsyncEventProbe/record(_:)`` from any isolation, and a test
`await`s ``AsyncEventProbe/wait(forAtLeast:timeout:)`` until enough events land, then reads
``AsyncEventProbe/events``. This is genuinely beyond Swift Testing's native `Confirmation`,
which only *counts within a closure* — it can neither suspend-until-a-count, expose the
recorded events for inspection, nor diagnose a stall. The probe's timeout is itself
**clock-injectable**, so under a ``TestClock`` even the *timeout* costs no real time:
the wait ends only when the events arrive or the test advances the clock past the deadline.

### Why it matters

Both types are backed by one internal `ContinuationRegistry` — a `Mutex`-guarded heap of
parked continuations keyed by deadline (clock) or event threshold (probe). Continuations
always resume **outside** the lock, and cancellation removes a parked waiter in O(1) and
resumes it with `CancellationError`. That shared core is why a hung test points at a real
boundary instead of deadlocking, and why thousands of timeout tests can run in the time it
takes to read this sentence.

## Using it

**Sequence with ``TestClock/sleeperCount``, don't guess.** The deterministic pattern is:
spawn the work, spin until it has parked, advance, assert.

```swift
let clock = TestClock()
let probe = AsyncEventProbe<Int>()
let worker = Task {
    try await clock.sleep(until: clock.now.advanced(by: .seconds(5)))
    probe.record(1)
}
while clock.sleeperCount == 0 { await Task.yield() }  // it has parked
clock.advance(by: .seconds(5))
_ = try await probe.wait(forAtLeast: 1)
#expect(probe.events == [1])
```

**Drive a timeout deterministically.** Inject the ``TestClock`` into the probe's wait; the
timeout fires only when *you* advance past it, so the test is exact and real-time-free.

```swift
let clock = TestClock()
let probe = AsyncEventProbe<Int>()
let advancer = Task {
    while clock.sleeperCount == 0 { await Task.yield() }
    clock.advance(by: .seconds(5))   // push past the deadline
}
await #expect(throws: AsyncEventProbeTimeoutError.self) {
    try await probe.wait(forAtLeast: 1, within: .seconds(5), clock: clock)
}
await advancer.value
```

**Drain at the end.** ``TestClock/runToLastSleeper()`` advances to the furthest pending
deadline, releasing every parked sleeper — the "let all remaining timers fire" step.

### When to use it

- Reach for ``TestClock`` whenever the code under test reads a clock or sleeps, and inject
  it where production defaults to `LiveClock` (see `AemiTestKitSeams`).
- Reach for ``AsyncEventProbe`` when a test must wait for an *observable effect* (a callback
  fired, a row written, a frame produced) rather than for a value returned from `await`.
- Prefer the clock-injectable ``AsyncEventProbe/wait(forAtLeast:within:clock:)`` over the
  real-time ``AsyncEventProbe/wait(forAtLeast:timeout:)`` convenience in any suite that
  already has a ``TestClock`` — it removes the last real-time wait.

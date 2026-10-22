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

The probe comes in the forms a test needs:

- **Count-only.** `AsyncEventProbe()` (an `AsyncEventProbe<Never>`) counts with ``AsyncEventProbe/record()``
  and stores no payload.
- **Conditions.** ``AsyncEventProbe/wait(until:timeout:)`` waits for a condition on the recorded events
  ("the events contain an error") instead of a polling loop. The condition is checked against the events so
  far and then against each further prefix in order, so the result does not depend on scheduling.
- **Diagnostics.** A probe has a label and remembers where it was created. A timeout throws
  ``AsyncEventProbeTimeoutError``, whose message names both and lists the ten most recent recorded events
  (each cut at 120 characters), so a stalled test shows what *did* happen.

`CountProbe` in `AemiTesting` is the app-tier sibling and follows the same rules.

### Why it matters

Both types are backed by one internal `ContinuationRegistry` — a `Mutex`-guarded heap of
parked continuations keyed by deadline (clock) or event threshold (probe). Continuations
always resume **outside** the lock, and cancellation removes a parked waiter in O(1) and
resumes it with `CancellationError`. That shared core is why a hung test points at a real
boundary instead of deadlocking, and why thousands of timeout tests can run in the time it
takes to read this sentence.

## Using it

**Sequence with a rendezvous, don't guess.** The deterministic pattern is: spawn the work,
wait until it has parked, advance, assert. ``TestClock/waitForSleepers(atLeast:)`` is the
rendezvous; it also counts sleepers that parked *before* the call, so it cannot miss one.

```swift
let clock = TestClock()
let probe = AsyncEventProbe<Int>()
let worker = Task {
    try await clock.sleep(until: clock.now.advanced(by: .seconds(5)))
    probe.record(1)
}
try await clock.waitForSleepers(atLeast: 1)  // it has parked
clock.advance(by: .seconds(5))
_ = try await probe.wait(forAtLeast: 1)
#expect(probe.events == [1])
```

**Drive a timeout deterministically.** Inject the ``TestClock`` into the probe's wait; the
timeout fires only when *you* advance past it, so the test is exact and real-time-free. The
timeout is the harness's own timer, so it parks *untracked*: it does not count toward
``TestClock/sleeperCount`` and cannot satisfy a rendezvous meant for the code under test.
Wait for it with ``TestClock/waitForUntrackedSleepers(atLeast:)``.

```swift
let clock = TestClock()
let probe = AsyncEventProbe<Int>(label: "writes")
let waiter = Task { try await probe.wait(forAtLeast: 1, within: .seconds(5), clock: clock) }
try await clock.waitForUntrackedSleepers(atLeast: 1)   // the timeout is armed
clock.advance(by: .seconds(5))                         // push past the deadline
await #expect(throws: AsyncEventProbeTimeoutError.self) { try await waiter.value }
```

**Stage a second wave.** ``TestClock/waitForSleepers(atLeast:)`` is satisfied by sleepers that
are already parked. To wait for *further* sleepers, take a ``TestClock/registrationMark()`` first
and wait with ``TestClock/waitForSleepers(_:after:)``; the mark is taken synchronously, so it does
not matter which task runs first. ``TestClock/waitForAdditionalSleepers(_:)`` takes its mark when
the call *runs*, so a wait spawned beside the work can start after the work's sleeper has already
parked and then wait for one that never comes.

```swift
let mark = clock.registrationMark()              // before the work exists
let work = Task { try await clock.sleep(for: .seconds(1)) }
try await clock.waitForSleepers(1, after: mark)  // counts the work's sleeper, whenever it parked
```

**End a test cleanly.** ``TestClock/runToLastSleeper()`` advances to the furthest pending
deadline, making every parked sleeper's sleep *succeed* — the "let all remaining timers fire" step.
``TestClock/drain()`` does the opposite: it throws `CancellationError` into everything still parked,
sleepers and rendezvous waiters alike, without moving time, so a task the code under test left
sleeping on purpose finishes instead of outliving the test. ``TestClock/advance(to:)`` jumps to an
instant atomically, and the clock's `description` lists the deadlines that are pending when a
rendezvous hangs.

> Important: `Clock.sleep(for:)` is a protocol extension that reads `now` and *then* parks, so an
> `advance` in between makes the sleep return without parking. The clock cannot close that window for
> generic callers; close it by waiting for the sleeper to park before you advance.

**Cancellation and order.** A probe wait in an already cancelled task throws `CancellationError` at
once, even if its boundary was reached; cancelling a suspended wait throws and unregisters it.
Waiters are resumed in ascending threshold order and, among equals, in the order they began waiting.

### When to use it

- Reach for ``TestClock`` whenever the code under test reads a clock or sleeps, and inject
  it where production defaults to `LiveClock` (see `AemiTestKitSeams`).
- Reach for ``AsyncEventProbe`` when a test must wait for an *observable effect* (a callback
  fired, a row written, a frame produced) rather than for a value returned from `await`.
- Prefer the clock-injectable ``AsyncEventProbe/wait(forAtLeast:within:clock:)`` over the
  real-time ``AsyncEventProbe/wait(forAtLeast:timeout:)`` convenience in any suite that
  already has a ``TestClock`` — it removes the last real-time wait.
- Reach for ``AsyncEventProbe/wait(until:timeout:)`` when what matters is the *content* of the events,
  and for the count-only form when only the number does.

---
status: accepted
date: 2026-11-20
---

# 0034 — Waits for what announces nothing: `waitUntil`, `withDeadline`, `KeyValueProbe`

## Context

The kit's waits all need an event: `AsyncEventProbe` a recording site, `TaskProviderSpy` a seam, `waitForObservedState` an
`@Observable` model, `TestClock` a sleeper. What a test often waits for announces nothing: a waiter registered on a gate, a
resource pool's queue, a view laid out, a socket's port. Consumers wrote the same three things each time, and the kit's own
tests did too (63 `Task.yield` loops and fixed sleeps in aemi's tests, found 2026-11-20):

- `while !condition { await Task.yield() }` — spins without bound, never says what it waited for, and hangs a failing test until
  the runner's time limit.
- A task group racing an operation against `Task.sleep` — rewritten in each file (Sunset had five).
- A poll over properties that key-value observing already announces (`WKWebView.isLoading`), every 25 ms.

Sunset wrote these as test support first (its `Poll`, `Deadline`, `KeyValueProbe`), then asked for them here.

## Decision

- **`waitUntil(within:every:clock:label:…)`**, and an over-real-time form with a 30 s hang guard and a 1 ms interval. It looks
  first without waiting; on a `TestClock` each further look waits for the clock to move. A timeout throws
  `AsyncEventProbeTimeoutError` (`isPredicateWait`, `recorded` the number of looks) pointing at the call site: one error type
  for every wait in the kit.
- **`withDeadline(within:clock:_:)`**: the operation's value, or `nil` once the deadline passes; the loser is cancelled. The
  deadline is an untracked sleeper on a `TestClock`.
- **`KeyValueProbe(object, keyPath)`**: the current value and each change as `AsyncEventProbe` events, from any thread; `wait(until:)`
  on the latest value, `wait(history:)` on all of them. Behind `canImport(ObjectiveC)`.
- An event, when there is one, is still the first choice: a poll can miss a value that came and went between looks. The
  documentation says so on each.
- The kit's own tests use them: every `Task.yield` loop and every sleep that stood for "until it has happened" is gone.
  `ResourcePool.waiterCount` and `BlockingOffloadPool.queuedCount` (internal) were added so that their tests wait for the
  queue, not for 50 ms. A wait that stood for "it has not happened" is now an assertion on a count that settles synchronously
  (a registration, an advance, a cancellation handler).

## Consequences

- `AemiTesting` (the app-level kit) does not get copies: its tests import `func AemiTestKit.waitUntil`, since its `TestClock`
  is a different type.
- What is left of real time in aemi's tests is input, not waiting: uneven work durations in `forEachConcurrently`'s test, and
  `Task.sleep` as a cancellation point in a task that parks forever.

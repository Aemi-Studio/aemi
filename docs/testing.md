# Testing

| Product | Use it for |
| --- | --- |
| `AemiTesting` | Testing application code that uses `AemiCore` task providers: clocks, gates, probes, semaphores, and spies. |
| `AemiTestKit` | Library and runtime tests: seeded data, fuzzing helpers, temporary files, allocation checks, clocks, and task coordination. |
| `AemiTestKitSeams` | The runtime task/clock interfaces re-exported for test support. |

Add testing products to test targets. `AemiTesting` and `AemiTestKit` have
distinct clock, probe and task-provider types (they conform to different
`TaskProvider` protocols); select the kit that matches the production module
rather than importing both unqualified.

The two kits follow the same rules, so a test reads the same against either:

| | `AemiTestKit` | `AemiTesting` |
| --- | --- | --- |
| Event probe | `AsyncEventProbe<Event>`: count waits and `wait(until:)` conditions, count-only form (`AsyncEventProbe()`), label and creation site, a timeout message that lists the 10 most recent events, clock-injectable timeouts; real-time default 30 s (a hang guard, so a long default costs time only when a test is stuck) | `CountProbe<Event>`: the same, including the 30 s default, except a wait returns nothing |
| Clock | `TestClock`: `sleeperCount`, `waitForSleepers(atLeast:)`, registration marks (`registrationMark()`, `waitForSleepers(_:after:)`), `advance(to:)`, `runToLastSleeper()`, `drain()`, untracked harness timers | `TestClock`: the same; sleepers resume in queued order rather than deadline order |
| Task provider spy | `TaskProviderSpy`: work and observation tracking, `cancelPendingWork()`, `cancelObservations()`, a `deinit` safety net, clock-injectable waits, a 30 s default timeout | `TaskProviderSpy`: the same, for `AemiCore`'s provider |
| Doubles and helpers | `ManualCompletion`, `deallocationProbe(of:)`, `waitForObservedState` | the same |
| Measurement | per-thread `mallocDelta` and `AllocationWindow`, `recordBenchmark`, the `.bench` tag | |

`AemiMetrics` adds `measureRate(units:rounds:_:)`, the best of several rounds by wall time and retired
instructions per unit. `deallocationProbe(of:)` needs the Objective-C runtime and `waitForObservedState` the
Observation module; both are compiled out elsewhere.


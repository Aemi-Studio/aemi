# Coordinating spawned tasks

Settle a tree of `Task`s to a known boundary instead of racing on results after an
arbitrary delay.

## The problem

Async library code spawns work — a write-behind flush, a background index rebuild, a
fan-out of requests. Testing it is deceptively hard: the moment under test isn't a value
returned from `await`, it's the *completion of detached work* that the API kicked off and
forgot. The usual fixes are both bad:

- **Sleep and hope.** `try await Task.sleep(for: .milliseconds(50))` then assert. Slow,
  flaky, and it encodes a guess about scheduling into the test.
- **Race on a serial result.** Compare outputs after triggering, hoping the background
  task finished first. Passes locally, fails under load.

Worse, the spawned work is often *transitive*: the task you triggered spawns more tasks.
Waiting for "the first one" misses the rest.

## The design

AemiTestKit splits this into a **seam** and a **spy**.

The seam is the `TaskProvider` protocol (in `AemiTestKitSeams`): async-heavy library code
spawns through `provider.task { … }` instead of a raw `Task { }`. In production the
provider defaults to `LiveTaskProvider`, a transparent forward to `Task.init` — so shipping
code behaves byte-for-byte as if the seam weren't there. Each spawn carries a role: `.work`
is application work a test waits for; `.observation` is a long-lived loop (a stream, a
watcher) that never finishes on its own.

In tests you inject ``TaskProviderSpy``. It spawns *real* tasks (so the work actually runs)
while tracking them, and ``TaskProviderSpy/waitForAllTasks(timeout:)`` settles them
**transitively**: two internal ``AsyncEventProbe``s count every `.work` spawn and every
completion, and the settle loop waits for all-spawned-so-far to complete, then re-checks
whether that wait itself spawned more — until the spawn count stabilizes with everything
done. `.observation` tasks are excluded, so awaiting them can never hang the suite.

### Why it matters

The deadline is **clock-injectable**, so under a ``TestClock`` settling is real-time-free,
and a genuinely hung task surfaces as an ``AsyncEventProbeTimeoutError`` pointing at the
probe rather than as a silent suite hang. The seam costs production nothing yet gives tests
an exact "all the work this triggered has finished" boundary — the thing `Task.sleep` only
approximates.

## Using it

Default a `TaskProvider` parameter to live, inject the spy in tests:

```swift
// Library
func rebuildIndex(using tasks: any TaskProvider = LiveTaskProvider()) {
    tasks.task { await self.flushPending() }
}

// Test
@Test func `rebuild settles all background work`() async throws {
    let spy = TaskProviderSpy()
    let written = AsyncEventProbe<Int>()
    subject.rebuildIndex(using: spy)         // spawns .work transitively
    try await spy.waitForAllTasks()          // settles the whole tree
    #expect(spy.completedCount == spy.spawnedCount)
}
```

Tag the genuinely-unbounded loops so the spy doesn't wait on them:

```swift
tasks.task(role: .observation) {
    for await event in stream { handle(event) }   // never completes — excluded from settling
}
```

### When to use it

- Use the `TaskProvider` seam in any library that spawns detached `Task`s whose completion
  a test needs to observe. Keep the storage kernels that never spawn free of it.
- Use ``TaskProviderSpy`` instead of `Task.sleep` whenever a test asserts on the *effect*
  of triggered async work.
- Reach for ``AsyncEventProbe`` directly (see <doc:DeterministicTime>) when you control the
  recording site but not a `TaskProvider` seam.

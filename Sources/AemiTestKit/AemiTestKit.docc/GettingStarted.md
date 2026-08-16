# Getting started

Add AemiTestKit to a test target and reach for the helper that matches the hard part of
the test you're writing.

## Overview

AemiTestKit is consumed the way any Swift Testing support library is: a package depends on
it, and a test target links the `AemiTestKit` product. Production targets that only need a
seam link `AemiTestKitSeams` instead.

### Add the dependency

```swift
// Package.swift
.package(url: "https://github.com/g-cqd/AemiTestKit.git", from: "1.0.0"),

.testTarget(
    name: "MyLibraryTests",
    dependencies: [
        "MyLibrary",
        .product(name: "AemiTestKit", targets: ["AemiTestKit"]),
    ])
```

A production target that wants the live `TaskProvider` or `LiveClock` seam links only
the shipped-safe product:

```swift
.target(
    name: "MyLibrary",
    dependencies: [.product(name: "AemiTestKitSeams", targets: ["AemiTestKitSeams"])])
```

### Pick the tool for the problem

| The hard part of your test | Reach for |
| --- | --- |
| Time has to pass, but the suite must stay fast and deterministic | ``TestClock`` |
| Wait until async work has recorded *N* events, then inspect them | ``AsyncEventProbe`` |
| Settle a batch of spawned tasks without racing on results | `TaskProvider` + ``TaskProviderSpy`` |
| Force a specific interleaving of concurrent work | ``ThreadGate`` / ``AsyncGate`` |
| Reproduce a random corpus byte-for-byte across runs | ``SeededRNG`` + ``Seed`` |
| Prove a parser never traps on corrupt input | ``ByteMutator`` + ``fuzzNeverTraps(seed:iterations:edits:mutator:traceEnv:corpus:exercise:)`` |
| Prove a recursive descent survives its depth cap | `runOnConstrainedStack` + ``DepthSweep`` |
| Compare your output against a reference model | ``ReferenceComparison`` |
| Keep a heavy `#expect` from blowing the type-check budget | the typed asserts — see <doc:OraclesAndAsserts> |
| Need a private scratch directory or database path | ``TemporaryDirectory`` / `withTemporaryFilePath(prefix:extension:_:)` |

### A first deterministic-time test

```swift
import Testing
import AemiTestKit

@Test func `a sleeper wakes when time is advanced past its deadline`() async throws {
    let clock = TestClock()
    let woke = AsyncEventProbe<Int>()
    let sleeper = Task {
        try await clock.sleep(until: clock.now.advanced(by: .seconds(10)))
        woke.record(1)
    }
    while clock.sleeperCount == 0 { await Task.yield() }  // wait for it to park
    clock.advance(by: .seconds(10))                        // zero real time elapses
    try await sleeper.value
    #expect(woke.events == [1])
}
```

Continue with <doc:DeterministicTime> for the reasoning behind that pattern.

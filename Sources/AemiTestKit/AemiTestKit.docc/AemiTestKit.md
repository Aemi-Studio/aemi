# ``AemiTestKit``

The shared testing architecture for the g-cqd AD-family — deterministic time and
async coordination on one side, property / fuzz / oracle tooling on the other.

## Overview

Every package in the AD-family (AemiFoundation, ADJSON, ADSQL, ADDB, URLBuilder,
apple-docs) needs the same hard things from its test suite: time it can pin, async
work it can settle without racing, random corpora it can reproduce byte-for-byte, and
crash-injection that proves "this never traps." Before AemiTestKit those tools were
re-rolled — seven copies of a SplitMix64 generator, two hand-rolled manual clocks, a
handful of subtly different temp-directory helpers. AemiTestKit distils them into one
audited implementation so a bug fixed once stays fixed everywhere.

The kit is organized as **two pillars**:

- **Async & deterministic time** — a `Clock`-conforming ``TestClock`` whose hands move
  only when a test advances them, an ``AsyncEventProbe`` that suspends until *N* events
  are recorded (or until a condition on them holds), the `TaskProvider` seam and its settling
  ``TaskProviderSpy``, two interleaving gates: ``ThreadGate`` (blocks a real thread) and
  ``AsyncGate`` (suspends a task), and doubles for requests completed by hand
  (``ManualCompletion``).
- **Measurement** — per-thread allocation counting (``mallocDelta(_:)``, ``AllocationWindow``) and a
  benchmark results recorder (``recordBenchmark(_:environmentVariable:)``).
- **Property, fuzz & oracle tooling** — a seedable ``SeededRNG`` and named ``Seed``
  registry, the ``ByteMutator`` corruption engine with the ``fuzzNeverTraps(seed:iterations:edits:mutator:traceEnv:corpus:exercise:)``
  driver, `runOnConstrainedStack` plus ``DepthSweep`` for recursion limits, the
  ``ReferenceComparison`` differential oracles, and a family of typed *fixture* asserts.

### Design principles

A few commitments run through every helper, and they show up repeatedly in the articles
below:

- **Zero real-time waiting.** Anything time-dependent is driven by an injected clock, so
  a suite of a thousand timeout tests finishes in milliseconds and never flakes on a busy
  CI box.
- **Determinism over racing.** Async work is *settled* (waited to a known boundary), not
  compared after an arbitrary delay.
- **Process survival is the assertion.** Fuzz and crash-injection helpers prove a property
  by *not aborting*; a trap is the failure, caught by the exit-test harness.
- **Never trap the runner.** Every assert routes to `Issue.record`, so one failing
  expectation reports and the suite keeps going. Only the deliberately-tested traps abort.
- **Recursion-free.** The kit's own code is iterative throughout; the only recursion lives
  in a test that deliberately overflows a constrained stack.
- **Minimal dependency surface.** `AemiTestKitSeams` (the shipped-safe seams) carries no
  package dependencies; the full kit adds only swift-collections and swift-system, both
  with empty transitive graphs.

### Two products

AemiTestKit ships as two libraries so production code can adopt a seam without linking a
test framework:

- **`AemiTestKitSeams`** — ultra-thin, shipped-safe production seams (the `TaskProvider`
  protocol + `LiveTaskProvider`, and the `LiveClock` injection points). A library target
  links this; it pulls in nothing heavy.
- **AemiTestKit** — the test-only kit (everything in the articles below). It imports the
  toolchain's Swift Testing and re-exports the seams.

## Topics

### Essentials

- <doc:GettingStarted>

### Deterministic time & async coordination

- <doc:DeterministicTime>
- <doc:CoordinatingTasks>
- <doc:Gates>
- <doc:TestDoubles>
- ``TestClock``
- ``AsyncEventProbe``
- ``AsyncEventProbeTimeoutError``
- ``TaskProviderSpy``
- ``ManualCompletion``
- ``ThreadGate``
- ``AsyncGate``
- ``AsyncLatch``

### Allocations & benchmarks

- <doc:AllocationsAndBenchmarks>
- ``mallocDelta(_:)``
- ``expectAllocations(noMoreThan:sourceLocation:_:)``
- ``AllocationWindow``
- ``allocationCountingAvailable``
- ``sanitizerRuntimeLoaded``
- ``BenchmarkResult``
- ``BenchmarkOutput``
- ``recordBenchmark(_:environmentVariable:)``

### Property, fuzz & oracle tooling

- <doc:SeededRandomnessAndFuzzing>
- <doc:ConstrainedStack>
- <doc:OraclesAndAsserts>
- ``SeededRNG``
- ``Seed``
- ``ByteMutator``
- ``FuzzReport``
- ``DepthSweep``
- ``ReferenceComparison``
- ``GuardedBytes``

### Scratch files & test selection

- <doc:TemporaryFiles>
- <doc:TestTags>
- ``TemporaryDirectory``

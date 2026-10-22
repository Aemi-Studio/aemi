# Allocations and benchmarks

Pin how many heap allocations a hot path makes, and record measured figures for a tool that
tracks them over time.

## The problem

A copy, a box or an un-reserved array growth on a hot path is invisible to a functional test, and a
wall-clock assertion on it is flaky. Two kinds of check hold up: a **count of allocations**, which is
deterministic, and a **recorded figure** that a gate compares against a committed baseline with a
tolerance.

## Counting allocations

``mallocDelta(_:)`` counts the heap allocations a synchronous body makes, and ``expectAllocations(noMoreThan:sourceLocation:_:)``
asserts a ceiling on that count. The count is **per thread**: only the thread that runs the body is
counted, so test suites running in parallel cannot add their allocations to your measurement. Warm
the body up once before measuring, so one-time lazy initialization does not skew the delta.

Measurements share one lock, so a second one started while another runs waits for it, and one that
nests inside another traps instead of deadlocking.

Counting hooks libmalloc's logger, so it exists only on Darwin, and only without a sanitizer
(``sanitizerRuntimeLoaded``): ``allocationCountingAvailable`` says whether it does, and elsewhere the
body still runs and the measurement reports `nil`.

### Counting a thread of its own

A loop that runs on a thread of its own, driven from another, cannot be wrapped in a closure.
``AllocationWindow`` splits the measurement: the counted thread names itself, and any thread opens and
closes the window.

```swift
let counted = AllocationWindow.watchCurrentThread()   // on the loop's thread, before the window opens
// … on the driving thread, once the loop is warm:
AllocationWindow.begin(watching: counted)
// … the loop runs …
let allocations = AllocationWindow.end()              // on the thread that called begin
```

Pass the token from ``AllocationWindow/watchCurrentThread()`` to ``AllocationWindow/begin(watching:)``.
Without it `begin` falls back to the thread named last — one process-wide slot — so two threads that name
themselves before either window opens can swap.

## Recording benchmarks

A benchmark measures and records instead of asserting. Tag it `.bench`, and add `.benchmarksRequested`
so the default `swift test` skips it: Swift Testing cannot exclude a tag from a run, but a condition
trait can disable a test.

```swift
@Test(.tags(.bench), .benchmarksRequested)
func `parse throughput`() async {
    let rate = await measureRate(units: Double(corpus.count)) { parseAll(corpus) }
    recordBenchmark(BenchmarkResult(
        name: "parse.throughput", unit: "MiB/s", direction: .higher,
        value: rate.perSecond / 1_048_576, tolerance: 0.05, enforced: false))
    if let instructions = rate.instructionsPerUnit {
        recordBenchmark(BenchmarkResult(
            name: "parse.instructions", unit: "instructions/byte", direction: .lower,
            value: instructions, tolerance: 0.02))
    }
}
```

``recordBenchmark(_:environmentVariable:)`` appends one JSON object per line to the file named by an
environment variable — `AEMI_BENCH_OUTPUT` by default, set by whatever tool runs the benchmarks. Pass
``BenchmarkOutput`` a different name (`recordBenchmark(_:environmentVariable: "MYPKG_BENCH_OUTPUT")`,
`.benchmarksRequested(environmentVariable:)`) to let a package own its variable. Each line is written
with a single `write` on an `O_APPEND` descriptor, so benchmarks running at once cannot interleave their
lines; with no file named, recording does nothing.

`measureRate(units:rounds:_:)` lives in `AemiMetrics`. It runs the work several times and keeps the best
round — noise only ever slows a round — reporting units per second and, where the platform reports them,
retired instructions per unit. Instruction counts hardly depend on what else the machine is doing, so
they are the figures worth enforcing; wall-clock figures are worth reporting and not enforcing.

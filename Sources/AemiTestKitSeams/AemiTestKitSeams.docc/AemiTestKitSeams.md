# ``AemiTestKitSeams``

A stable re-export name for the shipped-safe production seams, which now live in the
zero-dependency **`AemiRuntime`** package.

## Overview

Most of AemiTestKit is test-only. But a couple of its tools require *cooperation from
production code*: to settle spawned tasks (see `<doc:CoordinatingTasks>`) a library must
spawn through a provider, and to pin time a library's datetime functions must read an
injected clock. Those injection points can't live in the test-only module, because then
shipping code couldn't call them.

They used to live here. They now live in the `AemiRuntime` leaf package — a zero-dependency,
shipped-safe module an async-heavy library links *directly*, so a production library (such as
ADJSON) no longer depends on a package named "TestKit". `AemiTestKitSeams` is kept as a thin
`@_exported import AemiRuntime`, so every existing `import AemiTestKitSeams` call site keeps
working and the seam symbols below remain documented here. The storage kernels that never spawn
or read a clock still link nothing at all.

Everything here is designed to be invisible in production: the live defaults behave
byte-for-byte as if the seam weren't present, so adopting a seam changes no behavior and
adds no measurable cost. Only a test swaps in a double.

### The seam pattern

A seam is a tiny protocol (or function-typed injection point) with a transparent live
default:

- ``TaskProvider`` mirrors `Task.init`; the default ``LiveTaskProvider`` forwards straight to
  it. A library spawns `provider.task { … }`; a test passes the kit's settling spy instead.
  ``TaskRole`` lets a spawn declare whether it's `.work` (a test waits for it) or
  `.observation` (a never-ending loop the test must *not* wait for).
- ``LiveClock`` is the live source for "what time is it." A datetime function takes a
  ``EpochSecondsProvider`` defaulting to ``LiveClock/epochSeconds``; a test passes a closure
  returning a fixed instant — the first deterministic `datetime('now')`. ``LiveClock`` reads
  the same `clock_gettime` source the AD-family already used, so defaulting to it changes
  nothing.

### Why epoch seconds and monotonic nanoseconds are separate

``EpochSeconds`` (wall clock, `CLOCK_REALTIME`) answers "what calendar time is it" and can
jump when the system clock is set; ``MonotonicNanosecondsProvider`` (`CLOCK_MONOTONIC`)
answers "how much time has elapsed" and never runs backwards. Durability timeouts and
server-timing must use the monotonic source — a wall-clock that steps backward would make a
timeout fire early or never. Keeping the two provider types distinct makes that choice
explicit at every call site.

## Topics

### Task spawning seam

- ``TaskProvider``
- ``LiveTaskProvider``
- ``TaskRole``

### Clock seam

- ``LiveClock``
- ``EpochSeconds``
- ``EpochSecondsProvider``
- ``MonotonicNanosecondsProvider``

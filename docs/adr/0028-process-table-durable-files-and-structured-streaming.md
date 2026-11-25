---
status: accepted
date: 2026-11-02
---

# 0028 — A process table, durable file primitives, structured streaming and a native SHA-256

## Context

Litmus, the family's mutation tester, runs thousands of subject processes under analyzerkit's `BoundedProcess` and
recorded what it had to build around aemi (Litmus `docs/upstream-recommendations.md`, items AE-1 to AE-9):

- `BoundedProcess` kills its child's process group. Two orphans of a timed-out mutant kept two cores busy for 2.5 hours
  (2026-11-02): `swift test` starts its testing helper in a new group, out of reach of a group kill. A simulator's test
  host is not even a descendant. Finding them needs the process table: sessions (a new group keeps its session),
  start times, and environments (a token the supervisor put there).
- Per-child CPU and memory: the kernel hands a child's usage back only through the call that reaps it, and
  swift-subprocess reaps its children itself. Its pull request swiftlang/swift-subprocess#226 (open, pitched on the
  forums) adds `ExecutionResult.resourceUsage`; until it lands, a supervisor can only sample a live child, or read the
  running total of the children it waited for.
- Writes in a strict-memory-safety client needed `unsafe` (`pread`/`pwrite` over raw buffers); a journal was created
  after a racy existence check; checkpoints were written with Foundation's `.atomic`, which does not sync the directory,
  so a renamed file can come back old after a power loss; a snapshot copied every byte where APFS can clone.
- `mapConcurrently` returns everything at the end, so a crash loses every verdict of a batch.
- `DirectoryWalk.Policy.isCancelled` runs on walker threads, where `Task.isCancelled` answers for no task.
- `ResourcePool` could only open resources from a path, and `checkout()` never waits.
- SHA-256 came from CryptoKit, which Linux does not have.

## Decision

1. **`AemiProcess`**, a new kernel-tier module (strict memory safety, in the `AemiFoundation` umbrella):
   `ProcessTable.list(user:)` with pid, parent, group, session and start time (microseconds since 1970; with the pid it
   tells a reused pid apart), `members(ofSession:)`, `session(of:)`, `environment(of:)` and
   `environment(of:contains:)`, `usage(of:)` (live user and system CPU, resident size, footprint and lifetime peak
   footprint) and `send(_:to:)`. Darwin reads `sysctl(KERN_PROC_UID)`, `KERN_PROCARGS2` and `proc_pid_rusage`
   (Mach ticks converted exactly); Linux reads `/proc`. macOS hides the environment of Apple platform binaries
   (measured: `/bin/sleep`, `/usr/bin/perl`); the session still finds them.
2. **Children's usage** in `AemiMetrics`: `ProcessProbe.childrenCPUNanos()` and `childrenPeakResidentBytes()`
   (`RUSAGE_CHILDREN`), exact for one child at a time, which is how a supervisor measures how many cores a suite keeps
   busy. **Waiting for swift-subprocess#226** for exact per-child accounting; `ProcessTable.usage(of:)` samples a live
   child meanwhile (accurate to the last sample).
3. **Durable files** in `AemiIO`: `PosixFile(creatingExclusively:)` (`O_CREAT | O_EXCL`, which also refuses a dangling
   link), safe `write(_:at:)` and `read(at:count:)` over `[UInt8]`, `AtomicFile.replace(at:with:durability:)`
   (exclusive temporary beside the target, sync, rename, directory sync) and `FileCopy.copy(from:to:)`
   (`clonefile` on Darwin, read and write otherwise; links, non-regular files and existing destinations refused).
   Spans were left out: Swift 6.3 and 6.4 disagree on how a span's unsafe accessors are spelled (see `Package.swift`).
4. **`forEachConcurrently(_:limit:_:each:)`** in `AemiRuntime`: results handed to the caller's closure in completion
   order, on the caller's task. A callback, not an `AsyncSequence`, so the transforms stay child tasks of the caller.
5. **`ResourcePool`** is generic over any `Sendable` resource, with a factory initializer and an `async acquire()` that
   waits (oldest waiter first, cancellation releases the waiter); the path initializers stay, for `PooledResource`.
6. **`DirectoryWalk.cancellableWalk(_:policy:)`** ties a walk to its task's cancellation; `isCancelled` says where it
   runs.
7. **`ContentDigest.sha256`** in `AemiKernel`: CommonCrypto (the CPU's SHA instructions) on Apple platforms, a
   portable FIPS 180-4 implementation elsewhere, held to the NIST vectors and, on Apple platforms, to CommonCrypto over
   random inputs and random splits. No package: swift-crypto would have added a dependency for Linux alone.
   *Superseded by ADR 0029*: `ContentDigest` moved to `AemiDigest`, on CryptoKit and swift-crypto.

## Consequences

Additive: no existing API changed its behaviour. `ResourcePool`'s generic constraint is relaxed, which every existing
use satisfies. analyzerkit's `BoundedProcess` builds its session reaping on `AemiProcess`; Litmus drops its own
`sysctl` code, its `ChildUsage` and its CryptoKit digest.

What is not covered: per-child usage is sampled, not exact, until swift-subprocess#226; `ProcessTable` on iOS, tvOS,
watchOS and visionOS compiles but sees only what the sandbox shows; the Linux paths are checked in the `swift:6.4`
container, not on a Linux host.

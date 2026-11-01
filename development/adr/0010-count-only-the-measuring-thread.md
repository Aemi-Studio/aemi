---
status: accepted
date: 2026-10-18
supersedes: the "not process-wide" mechanism in 0008
---

# 0010 — The allocation counter counts only the thread that measures

## Context

ADR-0008 found the counter exact on its own thread and concluded that threads warmed before `begin`
were invisible, which made cross-thread counts under-report. Later evidence shows the opposite
failure, and it is the one that broke real tests:

- Atelier's lexer ceiling (bound 4) failed in full-suite runs with a **minimum of 191 over 64
  samples**, while passing 5 of 5 isolated runs on the same build. The C counter had not changed.
- Reproduced directly: a fresh thread making 10,000 allocations inside a window added **10,008** to
  the count (quiet control 28, busy 10,036).

So the hook does see other threads, at least threads that first allocate inside the window. Counts
from other threads are unreliable in both directions, and never what a ceiling means to measure.

## Decision

`adtk_malloc_count_begin` records `pthread_self()`; the hook counts an allocation only when
`pthread_equal` matches that owner, and `end` clears it. `pthread_self` neither allocates nor locks,
so it is safe inside the allocator's hook. The header and `mallocDelta`'s documentation now state
the contract: a synchronous, single-threaded body, counted exactly on its own thread.

## Consequences

- Concurrent test suites can no longer fail an allocation ceiling. Taking a minimum across repeats
  remains useful for one-off work on the measuring thread, not for contamination.
- Work a measured body hands to another thread is not counted. Every consumer in the ecosystem
  already measures a synchronous body on its own thread (audited: Aemi, TerminalKit, Atelier,
  AemiJSON), so none loses coverage.
- New regression test: allocations another thread makes during a measurement are not counted. It
  failed before the change (10,008 leaked) and passes after. Aemi's suite: 535 tests, exit 0.
- Consumers need this revision to benefit: TerminalKit, AemiJSON and Atelier move their Aemi pins
  together, because SwiftPM accepts one revision per package identity.

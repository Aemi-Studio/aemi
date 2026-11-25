---
status: accepted
date: 2026-10-18
---

# 0009 — The test suite hangs intermittently, under load

## What was observed

`swift test -c release` on this package hung twice, both times with a `swiftpm-testing-helper`
process parked and zero CPU. Both hangs happened **while another SwiftPM build or push was running
on the same machine**. Three subsequent full runs, with nothing else competing, all completed in
normal time.

`--filter` runs of the same targets — including the 106-test `AemiTestKitTests` and the 34-test
`AemiKernelsTests` — complete in well under a second every time.

## What is claimed, and what is not

**Claimed:** the hang is real, it is intermittent, and it correlates with concurrent load rather
than with a particular test.

**Not claimed:** which test hangs, or why. It has not been localised. Under `--filter` nothing
hangs, so the trigger is a property of the suite *running as a whole* while the machine is busy.

## Why this is recorded rather than fixed now

The suite has timing-sensitive tests by design — load timeouts, semaphore FIFO ordering, blocking
offload, `TestClock` scheduling — and those are exactly the tests that misbehave when the machine
they run on is not the machine they assume. That is a hypothesis, and it is labelled as one: it has
not been tested, and the alternative — a genuine deadlock in one of those tests — has not been
excluded.

An intermittent hang that cannot be localised is worth naming precisely so the next person does not
spend an afternoon rediscovering it. Attributing it to a cause before measuring one would be the
same mistake this project keeps refusing elsewhere.

## Consequences

- A hung suite must not be treated as a failed one: the run is killed, and the change committed with
  the gap stated. That is what happened for `fold_ascii`, whose correctness is covered by an
  independent probe regardless.
- Anyone bisecting a hang here should start by making sure nothing else is building.

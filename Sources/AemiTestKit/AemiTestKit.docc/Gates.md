# Gates: forcing a deterministic interleaving

Hold a piece of concurrent work at a barrier so the rest provably piles up behind it —
without sleeps, and without guessing about the scheduler.

## The problem

Some bugs only appear under a *specific* interleaving. The canonical one is group commit:
a writer occupies the serial queue, and while it's busy, several more writes must enqueue
behind it so they batch into one fsync. To test "they batched," you need to *guarantee*
the holder is occupying the resource before the others arrive — a timing relationship that
`Task.sleep` can only make probable, never certain.

## The design

A gate is a one-shot barrier: a holder waits until the gate is opened, and meanwhile other
work is assembled behind it. AemiTestKit ships **two**, because there are two concurrency
worlds and they need different primitives:

- ``ThreadGate`` **blocks a real OS thread.** It wraps a `DispatchSemaphore`, so a holder
  running on a pthread or a dispatch queue parks the thread until the gate opens. This is
  the right tool for the engine paths that occupy a *real* serial resource (a writer queue
  on its own thread).
- ``AsyncGate`` **suspends a `Task`.** Its ``AsyncGate/waitUntilOpen()`` returns the
  cooperative thread to the pool while the holder is parked, and ``AsyncGate/open()``
  resumes the longest-waiting holder. This is the right tool for code already living on
  async/await — no blocked thread, and no priority inversion.

### Why two, and why it matters

You can't build ``ThreadGate`` out of a `Mutex`: a mutex is a lock (the same owner
acquires and releases it), whereas a gate hands control *from one thread to another* — that
is semaphore/condition semantics, which the `Synchronization` framework does not provide.
And you shouldn't build ``AsyncGate`` out of a `DispatchSemaphore`: blocking a cooperative
pool thread starves the async runtime and can't be priority-boosted. So the distinction is
fundamental, not stylistic — picking the wrong one either won't compile the behavior you
need or will quietly hurt the runtime. ``AsyncGate`` reuses the kit's internal continuation
registry (a `Mutex` plus parked continuations), so it is fully `Sendable`, recursion-free,
and `Dispatch`-free; a cancelled waiter throws `CancellationError` and unregisters.

> Note: ``ThreadGate`` creates its semaphore at value 0 and signals up for `initiallyOpen`,
> never at value 1. libdispatch traps when a `DispatchSemaphore` is destroyed below its
> creation value, so a pre-armed-and-consumed gate built the naive way would crash on
> deallocation. The kit's construction makes every balanced use safe to drop.

## Using it

The thread-blocking batch pattern, via `withThreadGatedBatch(hold:_:)`:

```swift
await withThreadGatedBatch(hold: { gate in
    occupyWriterQueue()
    gate.waitUntilOpen()        // blocks the queue's thread; later writes pile up behind it
    drainBatch()
}) { openGate in
    enqueueWrite(a); enqueueWrite(b); enqueueWrite(c)  // assembled while the holder is parked
    openGate()                  // release; the batch commits as one unit
}
```

The async equivalent, via `withAsyncGatedBatch(hold:_:)`, is identical in shape but suspends
the holder instead of blocking a thread. To sequence a test deterministically, wait for the
holder to park before opening:

```swift
let gate = AsyncGate()
let holder = Task { try await gate.waitUntilOpen(); /* … */ }
while gate.waiterCount == 0 { await Task.yield() }   // it has parked
gate.open()
```

### When to use which

- **``ThreadGate``** — the work occupies a real thread/queue (pthread engines, dispatch
  queues, anything blocking). It can cross into a detached holder task or a raw worker.
- **``AsyncGate``** — the work is structured concurrency (`Task`s, actors). Prefer it
  whenever the holder *can* suspend rather than block; it keeps the cooperative pool healthy.
- For "wait until N events happened" rather than "hold at a barrier," use ``AsyncEventProbe``
  (see <doc:DeterministicTime>) instead of a gate.

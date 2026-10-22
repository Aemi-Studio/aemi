# Doubles and observation helpers

Complete requests by hand, wait for an object to be released, and wait for `@Observable` state to
change — without sleeping or yielding in a loop.

## Completing requests by hand

``ManualCompletion`` is a double for a service whose requests a test completes itself, in any order.
The code under test calls ``ManualCompletion/receive()``; each call registers a numbered request and
suspends. The test waits on ``ManualCompletion/requests`` (a count-only probe) until the requests it needs
are registered, then completes them:

```swift
let completion = ManualCompletion<Profile>()
let subject = ProfileLoader(fetch: { try await completion.receive() })

subject.refresh()                        // request 0
subject.refresh()                        // request 1
try await completion.requests.wait(forAtLeast: 2)

try completion.complete(at: 1, returning: newer)
try completion.complete(at: 0, returning: older)   // arrives late
#expect(subject.profile == newer)        // an older response must not overwrite newer state
```

Cancelling the task that called `receive()` leaves its request pending on purpose: a cancelled
service may still return a result, and the code under test has to reject it. Complete every registered
request, cancelled ones included, so their callers can finish; ``ManualCompletion/pendingCount`` shows what
is outstanding. Completing a request that was never registered, or twice, throws
``ManualCompletion/CompletionError``.

## Waiting for an object to be released

`deallocationProbe(of:label:sourceLocation:)` returns a count-only probe that records when the object is
deallocated, without retaining it. Use it for an object its owner releases asynchronously:

```swift
var session: URLSession? = makeSession()
let released = deallocationProbe(of: session!)
session = nil
try await released.wait(forAtLeast: 1)
```

It hangs a recorder on the object as an associated object, so it exists where the Objective-C runtime does.

## Waiting for observed state

`waitForObservedState(timeout:label:sourceLocation:_:)` suspends a main-actor test until a condition over
`@Observable` state is true, re-evaluating it each time a property it read changes:

```swift
try await waitForObservedState { model.phase == .ready }
```

It registers one observation per round and records an event when it fires, so cancellation, the deadline
and the registration race all come from the event probe. The deadline is fixed once — a change that does
not satisfy the condition does not extend it — and
`waitForObservedState(within:clock:label:sourceLocation:_:)` runs it on a ``TestClock``. The condition must
read only observable properties, or changes will not wake the waiter. Available where the Observation module is.

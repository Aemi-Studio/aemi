# Constrained-stack depth testing

Run recursion-prone code on a deliberately small stack, so an unbounded or mis-sized depth
cap fails loudly instead of passing by luck.

## The problem

Recursive-descent parsers, tree walkers, and serializers have a depth limit whether the
author wrote one or not — the OS stack. The danger is that tests run on the **main test
thread, which has a multi-megabyte stack**, so a parser that recurses far too deep still
returns fine in the suite and only blows up in production on a worker thread with a 512 KiB
stack. The bug is real; the test environment hides it. The AD-family hit exactly this: a SQL
parser that SIGBUS'd only on the engine's worker stack, invisible to a suite that exercised
it on the main thread.

## The design

`runOnConstrainedStack` runs a closure on a freshly spawned thread whose
stack is **pinned** to a chosen size (512 KiB by default — the AD-family's worker-stack
floor), blocks until it joins, and returns the result. Survival of the join *is* the
assertion: if the work overflows the pinned stack it dies with SIGBUS rather than returning,
so any caller that completes has proven the work fits. The multi-MB main stack that would
mask the overflow is taken out of the picture.

``DepthSweep`` builds the canonical set of depths to probe: shallow values, each cap
*straddled* at `cap-1 / cap / cap+1`, and a far-past-cap depth — then runs the body at every
one, each on a constrained stack. A missing or mis-sized recursion cap therefore surfaces as
a SIGBUS at a specific depth instead of passing silently.

### Why it matters, and why it's iterative

This is the one place the kit deliberately *invites* a crash, and it pairs with Swift
Testing's exit tests: `#expect(processExitsWith: .failure) { runOnConstrainedStack … }`
asserts that a planted unbounded recursion really does abort, proving the harness catches
what it claims to. Note that the kit's own sweep machinery is built **iteratively** — the
depth lives entirely in your `body`, never in the helper — so the only recursion under test
is the code you point it at.

## Using it

Lock in a parser's depth cap as a regression:

```swift
DepthSweep.around(Parser.maxDepth, upTo: 3000).run { depth in
    let json = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
    // total: parse the depth-`n` shape, recording any *unexpected* outcome itself.
    expectThrows({ try Parser.parse(json) }, where: { (e: ParseError) in e == .tooDeep })
}
```

Reaching the end of the sweep proves none of the straddled depths overflowed the pinned
stack — i.e. the cap fires *before* the stack does, at every boundary.

Prove the guard itself works (an exit test):

```swift
@Test func `a planted unbounded recursion overflows the constrained stack`() async {
    await #expect(processExitsWith: .failure) {
        runOnConstrainedStack(stackSize: 256 * 1024) { /* deliberately bottomless recursion */ }
    }
}
```

### When to use it

- Use ``DepthSweep`` for any code with a recursion depth cap; set the `stackSize` to the
  smallest stack the code will run on in production, not the test default.
- Use `runOnConstrainedStack` directly when you need a single result computed on a pinned
  stack rather than a swept range.
- The `body` must be *total* — catch its own typed errors and record unexpected outcomes;
  only an unrecoverable overflow should fail to return.

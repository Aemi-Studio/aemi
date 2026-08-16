import Foundation
import Testing

@testable import AemiTestKit

/// Exit tests for the genuine trap paths the kit exposes: a `precondition` it owns,
/// and the constrained-stack runner's whole purpose — surfacing a stack overflow as a
/// process abort rather than a silent pass.
struct ExitTests {
    @Test
    func `uniform(0) trips its precondition`() async {
        await #expect(processExitsWith: .failure) {
            var rng = SeededRNG(seed: 1)
            _ = rng.uniform(0)
        }
    }

    @Test
    func `a planted unbounded recursion overflows the constrained stack`() async {
        await #expect(processExitsWith: .failure) {
            // `limit` is read from the environment (never set in practice → .max), so the
            // compiler cannot prove the base case is unreachable and won't raise its
            // infinite-recursion diagnostic — yet at runtime the call recurses far enough
            // to overflow the 256 KiB stack (SIGBUS), which is exactly what this asserts.
            let limit =
                ProcessInfo.processInfo.environment["ADTESTKIT_RECURSION_LIMIT"]
                .flatMap(Int.init) ?? .max
            // Optimizer-proofed: in a release build the original version was folded away entirely
            // (tail-recursion elimination turns the accumulating self-call into a loop, and scalar
            // evolution folds the loop to a closed form — the child exited 0 and the exit test
            // failed). `@_optimize(none)` compiles the probe itself at -Onone, so the recursion
            // keeps real, growing native frames in every configuration; `@inline(never)` keeps the
            // call a call, and the branch on the result stops the caller from discarding it.
            @inline(never) @_optimize(none) @Sendable func deepen(_ depth: Int) -> Int {
                if depth >= limit { return depth }
                let pad = [depth, depth &+ 1]
                return deepen(depth &+ 1) &+ pad[0]
            }
            runOnConstrainedStack(stackSize: 256 * 1024) {
                if deepen(0) == Int.min { print("unreachable: planted recursion folded") }
            }
        }
    }
}

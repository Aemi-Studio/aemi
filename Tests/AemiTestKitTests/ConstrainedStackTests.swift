import Foundation
import Testing

@testable import AemiTestKit

struct ConstrainedStackTests {
    @Test
    func `runs body on a worker and ferries the result back`() {
        let result = runOnConstrainedStack {
            (1 ... 100).reduce(0, +)
        }
        #expect(result == 5050)
    }

    @Test
    func `Void specialization runs to completion`() {
        let box = LockedBox(0)
        runOnConstrainedStack {
            box.set(7)
        }
        #expect(box.get() == 7)
    }

    @Test
    func `DepthSweep.around straddles each cap and stays sorted/unique`() {
        let sweep = DepthSweep.around([16, 48, 256], upTo: 3000)
        #expect(sweep.depths == sweep.depths.sorted())
        #expect(Set(sweep.depths).count == sweep.depths.count)
        for cap in [16, 48, 256] {
            #expect(sweep.depths.contains(cap - 1))
            #expect(sweep.depths.contains(cap))
            #expect(sweep.depths.contains(cap + 1))
        }
        #expect(sweep.depths.contains(3000))
        #expect(sweep.depths.allSatisfy { $0 >= 1 && $0 <= 3000 })
    }

    @Test
    func `DepthSweep runs the body at every depth without overflowing`() {
        let visited = LockedBox<[Int]>([])
        // A bounded "recursion" that always fits 512 KiB: each depth does shallow work.
        DepthSweep.around([48, 256], upTo: 1000)
            .run { depth in
                visited.mutate { $0.append(depth) }
            }
        #expect(visited.get().count == DepthSweep.around([48, 256], upTo: 1000).depths.count)
    }
}

/// A tiny lock box for ferrying values out of a worker closure in tests.
final class LockedBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func set(_ v: T) {
        lock.lock()
        value = v
        lock.unlock()
    }
    func get() -> T {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
    func mutate(_ body: (inout T) -> Void) {
        lock.lock()
        body(&value)
        lock.unlock()
    }
}

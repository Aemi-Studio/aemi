import Synchronization
import Testing

@testable import AemiRuntime

/// A fake poolable handle whose `init?(path:)` fails for the sentinel path `"fail"`, so the
/// pool's all-or-nothing construction can be exercised without touching the filesystem.
private struct FakeHandle: PooledResource {
    let path: String
    init?(path: String) {
        guard path != "fail" else { return nil }
        self.path = path
    }
}

/// A fake handle whose factory fails on the Nth open, encoded in the path as `"failAt:<n>"`. It
/// counts opens in a process-wide `Mutex` keyed by that target so a test can assert the throwing
/// initializer reports the EXACT failing index — independent of Swift Testing's parallel execution
/// (the `Mutex` makes the count→compare atomic; no `nonisolated(unsafe)` shared latch).
private struct FailsAtIndexHandle: PooledResource {
    /// `[targetIndex: opensSoFar]` — the running open count per `"failAt:<targetIndex>"` path.
    private static let opens = Mutex<[Int: Int]>([:])

    let path: String
    init?(path: String) {
        guard let target = Self.parseTarget(path) else {
            self.path = path  // not a sentinel path → always succeeds
            return
        }
        let shouldFail = Self.opens.withLock { counts -> Bool in
            let index = counts[target, default: 0]
            counts[target] = index + 1
            return index == target
        }
        if shouldFail { return nil }
        self.path = path
    }

    /// The target index in a `"failAt:<n>"` path, or `nil` for any other path.
    private static func parseTarget(_ path: String) -> Int? {
        let prefix = "failAt:"
        guard path.hasPrefix(prefix) else { return nil }
        return Int(path.dropFirst(prefix.count))
    }
}

struct ResourcePoolTests {
    @Test
    func `builds exactly count resources`() {
        let pool = ResourcePool<FakeHandle>(path: "ok", count: 3)
        #expect(pool != nil)
        #expect(pool?.count == 3)
    }

    @Test
    func `count is floored at one`() {
        let pool = ResourcePool<FakeHandle>(path: "ok", count: 0)
        #expect(pool?.count == 1)
    }

    @Test
    func `a failing factory fails the whole pool (all-or-nothing)`() {
        let pool = ResourcePool<FakeHandle>(path: "fail", count: 2)
        #expect(pool == nil)
    }

    @Test
    func `the throwing initializer builds exactly count resources on success`() throws {
        let pool = try ResourcePool<FakeHandle>(diagnostic: "ok", count: 3)
        #expect(pool.count == 3)
    }

    @Test
    func `the throwing initializer floors count at one`() throws {
        let pool = try ResourcePool<FakeHandle>(diagnostic: "ok", count: 0)
        #expect(pool.count == 1)
    }

    @Test
    func `the throwing initializer surfaces the EXACT failing index, count, and path`() throws {
        // The factory fails on the 3rd open (index 2) of a pool of 4, so the error must pin index 2
        // — proving it reports the genuinely-failing position, not coincidentally the first. Pattern-
        // match the associated values rather than `==` so the error type needn't be `Equatable`
        // (it's a public leaf API; we don't widen its conformances just for a test).
        let error = try #require(throws: ResourcePoolError.self) {
            _ = try ResourcePool<FailsAtIndexHandle>(diagnostic: "failAt:2", count: 4)
        }
        guard case .resourceUnavailable(let index, let count, let path) = error else {
            Issue.record("expected .resourceUnavailable, got \(error)")
            return
        }
        #expect(index == 2)
        #expect(count == 4)
        #expect(path == "failAt:2")
    }

    @Test
    func `the failable init? still collapses a factory failure to nil (source-stable)`() {
        // The failable initializer delegates to the throwing one but discards the error — the
        // historical go/no-go contract callers depend on is unchanged.
        #expect(ResourcePool<FakeHandle>(path: "fail", count: 2) == nil)
        #expect(ResourcePool<FakeHandle>(path: "ok", count: 2) != nil)
    }

    @Test
    func `checkout drains, checkin restores`() {
        let pool = ResourcePool<FakeHandle>(path: "ok", count: 1)!
        let first = pool.checkout()
        #expect(first != nil)
        #expect(pool.checkout() == nil)  // drained
        pool.checkin(first!)
        #expect(pool.checkout() != nil)  // restored
    }

    @Test
    func `lease auto-returns the resource on scope exit`() {
        let pool = ResourcePool<FakeHandle>(path: "ok", count: 1)!
        do {
            guard let lease = pool.lease() else {
                Issue.record("expected a lease from a non-drained pool")
                return
            }
            #expect(lease.resource.path == "ok")
            #expect(pool.checkout() == nil)  // the one resource is leased out
        }
        // The lease went out of scope; its deinit checked the resource back in.
        #expect(pool.checkout() != nil)
    }

    @Test
    func `LiveTaskProvider forwards to a real Task`() async {
        let provider: any TaskProvider = LiveTaskProvider()
        let value = await provider.task { 42 }.value
        #expect(value == 42)
    }

    @Test
    func `LiveClock epoch seconds are within a sane modern range`() {
        // After 2020-01-01 and before 2100-01-01 — proves the seam reads a real clock.
        let now = LiveClock.epochSeconds()
        #expect(now > 1_577_836_800)
        #expect(now < 4_102_444_800)
    }
}

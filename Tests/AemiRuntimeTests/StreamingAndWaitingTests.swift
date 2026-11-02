import Synchronization
import Testing

@testable import AemiRuntime

private struct Slot: Sendable, Equatable {
    let index: Int
}

@Suite struct ForEachConcurrentlyTests {
    @Test func `every result arrives once, with its index, and no more than the limit run at once`() async throws {
        let running = Mutex(0)
        let peak = Mutex(0)
        var seen: [Int: Int] = [:]
        try await forEachConcurrently(Array(0 ..< 40), limit: 3) { item in
            running.withLock { value in
                value += 1
                peak.withLock { $0 = max($0, value) }
            }
            try await Task.sleep(for: .milliseconds(UInt64(item % 5)))
            running.withLock { $0 -= 1 }
            return item * 2
        } each: { index, result in
            #expect(seen[index] == nil)
            seen[index] = result
        }
        #expect(seen.count == 40)
        #expect(seen.allSatisfy { $0.value == $0.key * 2 })
        #expect(peak.withLock { $0 } <= 3)
    }

    @Test func `an error from the handler stops the map and is rethrown`() async throws {
        struct Stop: Error {}
        let started = Mutex(0)
        await #expect(throws: Stop.self) {
            try await forEachConcurrently(Array(0 ..< 100), limit: 2) { item in
                started.withLock { $0 += 1 }
                return item
            } each: { _, result in
                if result == 3 { throw Stop() }
            }
        }
        #expect(started.withLock { $0 } < 100)
    }

    @Test func `results are handled in completion order, not submission order`() async throws {
        var order: [Int] = []
        try await forEachConcurrently([0, 1], limit: 2) { item in
            if item == 0 { try await Task.sleep(for: .milliseconds(200)) }
            return item
        } each: { index, _ in
            order.append(index)
        }
        #expect(order == [1, 0])
    }
}

@Suite struct ResourcePoolWaitingTests {
    @Test func `a factory pool hands out each resource once`() throws {
        let pool = ResourcePool(count: 3) { Slot(index: $0) }
        let taken = [pool.checkout(), pool.checkout(), pool.checkout()].compactMap { $0 }
        #expect(Set(taken.map(\.index)) == [0, 1, 2])
        #expect(pool.checkout() == nil)
    }

    @Test func `a factory error builds no pool`() {
        struct Broken: Error {}
        #expect(throws: Broken.self) {
            _ = try ResourcePool(count: 2) { index throws(Broken) -> Slot in
                if index == 1 { throw Broken() }
                return Slot(index: index)
            }
        }
    }

    @Test func `acquire waits for a checkin, and waiters are served oldest first`() async throws {
        let pool = ResourcePool(count: 1) { Slot(index: $0) }
        let held = try #require(pool.checkout())
        let order = Mutex<[Int]>([])
        let first = Task {
            let slot = try await pool.acquire()
            order.withLock { $0.append(1) }
            pool.checkin(slot)
        }
        try await Task.sleep(for: .milliseconds(50))
        let second = Task {
            let slot = try await pool.acquire()
            order.withLock { $0.append(2) }
            pool.checkin(slot)
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(order.withLock { $0 }.isEmpty)
        pool.checkin(held)
        try await first.value
        try await second.value
        #expect(order.withLock { $0 } == [1, 2])
        #expect(pool.checkout() != nil)
    }

    @Test func `a cancelled waiter throws and takes nothing`() async throws {
        let pool = ResourcePool(count: 1) { Slot(index: $0) }
        let held = try #require(pool.checkout())
        let waiter = Task { try await pool.acquire() }
        try await Task.sleep(for: .milliseconds(50))
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        pool.checkin(held)
        #expect(pool.checkout() == held)
        // Cancelled before it asked: it never waits.
        let early = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await pool.acquire()
        }
        pool.checkin(held)
        _ = try? await early.value
    }

    @Test func `a lease acquired by waiting returns its resource`() async throws {
        let pool = ResourcePool(count: 1) { Slot(index: $0) }
        do {
            let lease = try await pool.acquireLease()
            #expect(lease.resource.index == 0)
            #expect(pool.checkout() == nil)
        }
        #expect(pool.checkout() != nil)
    }
}

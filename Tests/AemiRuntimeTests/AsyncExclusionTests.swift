//
//  AsyncExclusionTests.swift
//  HTTPConcurrencyTests
//
//  The async mutual-exclusion gate: at most one holder at a time *across suspension points*, FIFO
//  hand-off, and a cancelled waiter that neither consumes nor strands the exclusion. The first
//  property is the one an `actor` cannot give — an actor's methods are reentrant, so a second caller
//  enters the moment the first `await`s — and it is why this type exists, so it is asserted directly.
//
//  Every interleaving below is sequenced by a signal the code under test emits (an ``AsyncEventProbe``
//  recorded *inside* the critical section) or by ``AsyncExclusion/waitForWaiters(atLeast:)``. No test
//  here spins on `Task.yield()` or sleeps: each assertion is made at a point the gate has confirmed.
//

internal import AemiRuntime
internal import Synchronization
import Testing

@testable import AemiTestKit

@Suite("AsyncExclusion")
struct AsyncExclusionTests {
    @Test(arguments: [4, 16, 64])
    func `a read-modify-write that yields mid-update loses nothing`(holders: Int) async {
        // The mutation oracle for the whole type. Each holder reads, hands the cooperative thread
        // away, then writes back what it read plus one — the classic lost update (CWE-362). Under a
        // working exclusion the interleaving cannot happen and the total is exact; remove the
        // exclusion and the `Task.yield()` guarantees overlapping updates, so the total falls short.
        // Unlike the parking tests below, this one FAILS rather than hangs, which is what makes it
        // the one to run a mutation against.
        final class Box: Sendable {
            let value = Mutex(0)
        }
        let exclusion = AsyncExclusion()
        let counter = Box()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< holders {
                group.addTask {
                    try? await exclusion.withExclusiveAccess {
                        let seen = counter.value.withLock(\.self)
                        await Task.yield()
                        counter.value.withLock { $0 = seen + 1 }
                    }
                }
            }
        }
        #expect(counter.value.withLock(\.self) == holders)
        #expect(!exclusion.isHeld)
    }

    @Test
    func `an uncontended acquisition runs the body and releases`() async throws {
        let exclusion = AsyncExclusion()
        let ran = try await exclusion.withExclusiveAccess { true }
        #expect(ran)
        #expect(!exclusion.isHeld)
        #expect(exclusion.waiterCount == 0)
    }

    @Test
    func `a second caller cannot enter while the first is suspended inside`() async throws {
        let exclusion = AsyncExclusion()
        let release = AsyncGate()
        let entered = AsyncEventProbe<Int>()
        let first = Task {
            try await exclusion.withExclusiveAccess {
                entered.record(1)
                try await release.waitUntilOpen()  // suspend while holding
            }
        }
        _ = try await entered.wait(forAtLeast: 1)  // the first caller is inside
        let second = Task {
            try await exclusion.withExclusiveAccess { entered.record(2) }
        }
        // The gate confirms the second caller is parked ON the exclusion, so the assertion below is
        // about mutual exclusion rather than about a task that merely has not started yet.
        try await exclusion.waitForWaiters(atLeast: 1)
        #expect(entered.events == [1])
        #expect(exclusion.isHeld)
        release.open()
        try await first.value
        try await second.value
        #expect(entered.events == [1, 2])
        #expect(!exclusion.isHeld)
    }

    @Test(arguments: [2, 3, 5])
    func `queued callers are handed the exclusion in arrival order`(waiters: Int) async throws {
        let exclusion = AsyncExclusion()
        let release = AsyncGate()
        let held = AsyncEventProbe<Int>()
        let order = AsyncEventProbe<Int>()
        let holder = Task {
            try await exclusion.withExclusiveAccess {
                held.record(0)
                try await release.waitUntilOpen()
            }
        }
        _ = try await held.wait(forAtLeast: 1)
        var queued: [Task<Void, any Error>] = []
        for index in 1 ... waiters {
            let waiter = Task { try await exclusion.withExclusiveAccess { order.record(index) } }
            queued.append(waiter)
            try await exclusion.waitForWaiters(atLeast: index)  // arrival order is now fixed
        }
        release.open()
        try await holder.value
        for task in queued {
            try await task.value
        }
        #expect(order.events == Array(1 ... waiters))
    }

    @Test
    func `a cancelled waiter throws and leaves the hand-off intact for the next`() async throws {
        let exclusion = AsyncExclusion()
        let release = AsyncGate()
        let held = AsyncEventProbe<Int>()
        let entered = AsyncEventProbe<Int>()
        let holder = Task {
            try await exclusion.withExclusiveAccess {
                held.record(0)
                try await release.waitUntilOpen()
            }
        }
        _ = try await held.wait(forAtLeast: 1)
        let doomed = Task { try await exclusion.withExclusiveAccess { entered.record(9) } }
        try await exclusion.waitForWaiters(atLeast: 1)
        let survivor = Task { try await exclusion.withExclusiveAccess { entered.record(2) } }
        try await exclusion.waitForWaiters(atLeast: 2)
        doomed.cancel()
        await #expect(throws: CancellationError.self) { try await doomed.value }
        release.open()
        try await holder.value
        try await survivor.value
        #expect(entered.events == [2])  // the cancelled waiter never ran; the survivor still did
        #expect(!exclusion.isHeld)
    }

    @Test
    func `a body that throws still releases the exclusion`() async throws {
        struct Boom: Error {}
        let exclusion = AsyncExclusion()
        await #expect(throws: Boom.self) {
            try await exclusion.withExclusiveAccess { throw Boom() }
        }
        #expect(!exclusion.isHeld)
        let reacquired = try await exclusion.withExclusiveAccess { true }
        #expect(reacquired)
    }

    @Test
    func `an already-cancelled acquisition throws without taking the exclusion`() async throws {
        let exclusion = AsyncExclusion()
        let started = AsyncEventProbe<Int>()
        let ran = AsyncEventProbe<Int>()
        let task = Task {
            started.record(0)
            try await Task.sleep(for: .seconds(3_600))
            try await exclusion.withExclusiveAccess { ran.record(0) }
        }
        _ = try await started.wait(forAtLeast: 1)
        task.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(ran.events.isEmpty)  // the body never ran
        #expect(!exclusion.isHeld)
        #expect(exclusion.waiterCount == 0)
    }

    @Test
    func `waitUntilHeld wakes deterministically when the exclusion is acquired`() async throws {
        let exclusion = AsyncExclusion()
        let release = AsyncGate()
        let waiter = Task { try await exclusion.waitUntilHeld() }
        let holder = Task {
            try await exclusion.withExclusiveAccess {
                try await release.waitUntilOpen()
            }
        }
        try await waiter.value
        #expect(exclusion.isHeld)
        release.open()
        try await holder.value
        #expect(!exclusion.isHeld)
    }
}

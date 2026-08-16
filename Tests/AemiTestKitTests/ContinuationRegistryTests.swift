import Synchronization
import Testing

@testable import AemiTestKit

/// Direct coverage for `ContinuationRegistry` — the park / wake / cancel core shared by
/// `TestClock` (key = wake deadline), `AsyncEventProbe` (key = event threshold) and `AsyncGate`
/// (all keys 0, FIFO by id). Those three exercise it only *indirectly*, so its two load-bearing
/// invariants — key ordering with a stable id tie-break, and lazy deletion of cancelled slots —
/// had no dedicated test. A regression here would surface as a confusing hang somewhere else.
@Suite(.tags(.concurrency))
struct ContinuationRegistryTests {
    /// Minimal harness mirroring how the real consumers drive the registry: the struct lives inside
    /// a `Mutex`, ids are vended before parking, cancellation unregisters through `remove(id:)`, and
    /// continuations always resume **outside** the lock.
    private final class Parking: Sendable {
        private struct State {
            var registry = ContinuationRegistry<Int, Int>()
        }
        private let state = Mutex(State())

        var count: Int { state.withLock { $0.registry.count } }
        var maxKey: Int? { state.withLock { $0.registry.maxKey } }

        func makeID() -> UInt64 { state.withLock { $0.registry.makeID() } }

        /// Park under `key`, resolving to the value delivered on wake. Cancellation unregisters and
        /// throws, exactly as `AsyncGate.waitUntilOpen()` does.
        func park(id: UInt64, key: Int) async throws -> Int {
            try await withTaskCancellationHandler {
                try await withUnsafeThrowingContinuation {
                    (continuation: UnsafeContinuation<Int, any Error>) in
                    state.withLock { $0.registry.park(id: id, key: key, continuation) }
                }
            } onCancel: {
                state.withLock { $0.registry.remove(id: id) }?.resume(throwing: CancellationError())
            }
        }

        /// Wake every live key `<= bound`. Returns how many continuations were resumed.
        @discardableResult
        func wake(upTo bound: Int, with value: Int) -> Int {
            let woken = state.withLock { $0.registry.wake(upTo: bound, with: value) }
            for (continuation, delivered) in woken {
                continuation.resume(returning: delivered)
            }
            return woken.count
        }

        /// Release the single longest-waiting live continuation. Returns whether one was found.
        @discardableResult
        func wakeOne(with value: Int) -> Bool {
            let woken = state.withLock { $0.registry.wakeOne() }
            woken?.resume(returning: value)
            return woken != nil
        }

        /// Suspend until `n` continuations are parked — the rendezvous `AsyncGate.waiterCount`
        /// exists for, so a test never races the park.
        func waitUntilParked(_ n: Int) async {
            while count < n {
                await Task.yield()
            }
        }
    }

    @Test
    func `wake releases every key at or below the bound and leaves the rest parked`() async {
        let parking = Parking()
        await withTaskGroup(of: Void.self) { group in
            for key in [30, 10, 40, 20] {
                let id = parking.makeID()
                group.addTask { _ = try? await parking.park(id: id, key: key) }
            }
            await parking.waitUntilParked(4)

            // The bound is INCLUSIVE: 10, 20 and 30 are due; 40 is not.
            #expect(parking.wake(upTo: 30, with: 1) == 3)
            #expect(parking.count == 1)
            #expect(parking.maxKey == 40)

            #expect(parking.wake(upTo: 40, with: 2) == 1)
            #expect(parking.count == 0)
            #expect(parking.maxKey == nil)
        }
    }

    @Test
    func `wakeOne releases in ascending key order, then by park order within a key`() async {
        let parking = Parking()
        let resumeOrder = Mutex<[Int]>([])
        // Two entries share key 5 so the id tie-break is observable: the one parked FIRST must win.
        let keys = [9, 5, 5, 1]

        await withTaskGroup(of: Void.self) { group in
            for (offset, key) in keys.enumerated() {
                let id = parking.makeID()
                group.addTask {
                    guard (try? await parking.park(id: id, key: key)) != nil else { return }
                    resumeOrder.withLock { $0.append(offset) }
                }
                // Park strictly one at a time so "first parked" is well-defined for the tied keys.
                await parking.waitUntilParked(offset + 1)
            }

            // Release one at a time, awaiting each resumption before the next, so the observed
            // order is the registry's and not the scheduler's.
            for released in 0 ..< keys.count {
                #expect(parking.wakeOne(with: 0))
                while resumeOrder.withLock({ $0.count }) <= released {
                    await Task.yield()
                }
            }
        }

        // key 1 (offset 3), then key 5 parked first (offset 1), then key 5 parked second
        // (offset 2), then key 9 (offset 0).
        #expect(resumeOrder.withLock { $0 } == [3, 1, 2, 0])
        #expect(parking.count == 0)
        #expect(!parking.wakeOne(with: 0))  // drained
    }

    @Test
    func `a cancelled waiter leaves the registry and is skipped by a later wake`() async throws {
        let parking = Parking()
        let survivorID = parking.makeID()
        let doomedID = parking.makeID()

        let survivor = Task { try await parking.park(id: survivorID, key: 10) }
        let doomed = Task { try await parking.park(id: doomedID, key: 5) }
        await parking.waitUntilParked(2)

        doomed.cancel()
        await #expect(throws: CancellationError.self) { try await doomed.value }

        // Liveness dropped immediately; the stale heap slot at key 5 is only skipped later.
        #expect(parking.count == 1)
        #expect(parking.maxKey == 10)

        // A wake spanning the cancelled key must resume the survivor exactly once and silently
        // drop the stale slot — this is the lazy-deletion contract.
        #expect(parking.wake(upTo: 10, with: 7) == 1)
        #expect(try await survivor.value == 7)
        #expect(parking.count == 0)
    }

    @Test
    func `wakeOne skips a cancelled slot and reaches the next live waiter`() async throws {
        let parking = Parking()
        let doomedID = parking.makeID()
        let survivorID = parking.makeID()

        // The doomed waiter holds the LOWEST key, so a naive wakeOne would return its stale slot.
        let doomed = Task { try await parking.park(id: doomedID, key: 1) }
        let survivor = Task { try await parking.park(id: survivorID, key: 2) }
        await parking.waitUntilParked(2)

        doomed.cancel()
        await #expect(throws: CancellationError.self) { try await doomed.value }

        #expect(parking.wakeOne(with: 42))
        #expect(try await survivor.value == 42)
        #expect(parking.count == 0)
    }

    @Test
    func `makeID vends distinct identifiers`() {
        let parking = Parking()
        let ids = (0 ..< 128).map { _ in parking.makeID() }
        #expect(Set(ids).count == ids.count)
    }

    @Test
    func `an empty registry reports no waiters and no maximum key`() {
        let parking = Parking()
        #expect(parking.count == 0)
        #expect(parking.maxKey == nil)
        #expect(!parking.wakeOne(with: 0))
        #expect(parking.wake(upTo: .max, with: 0) == 0)
    }
}

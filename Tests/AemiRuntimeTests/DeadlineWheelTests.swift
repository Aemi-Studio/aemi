import AemiRuntime
import AemiTestKit
import Synchronization
import Testing

@Suite("AemiRuntime — DeadlineWheel")
struct DeadlineWheelTests {
    @Test("Armed timers fire in earliest-first order and update in place on re-arm")
    func orderAndInPlaceRearm() {
        let wheel = DeadlineWheel()
        let fired = Mutex<[String]>([])

        let hA = wheel.register {
            fired.withLock { $0.append("A") }
            return .keepWatching
        }
        let hB = wheel.register {
            fired.withLock { $0.append("B") }
            return .stopWatching
        }

        wheel.arm(hA, until: .seconds(10))
        wheel.arm(hB, until: .seconds(5))
        #expect(wheel.earliest == .seconds(5))

        // Move A earlier than B in place.
        wheel.arm(hA, until: .seconds(2))
        #expect(wheel.earliest == .seconds(2))

        let turn1 = wheel.fireLapsed(at: .seconds(3))
        #expect(!turn1.isEmpty)
        #expect(turn1.action == .keepWatching)
        #expect(wheel.hasLapsed(hA))
        #expect(!wheel.hasLapsed(hB))
        #expect(wheel.earliest == .seconds(5))

        let turn2 = wheel.fireLapsed(at: .seconds(5))
        #expect(!turn2.isEmpty)
        #expect(turn2.action == .stopWatching)
        #expect(wheel.isEmpty)
        #expect(fired.withLock { $0 } == ["A", "B"])
    }

    @Test("Released handle generation rejects late arm/disarm and does not touch recycled occupant")
    func generationPreventsUseAfterRelease() {
        let wheel = DeadlineWheel()
        let fired = Mutex<[String]>([])

        let stale = wheel.register {
            fired.withLock { $0.append("stale") }
            return .keepWatching
        }
        wheel.release(stale)

        let fresh = wheel.register {
            fired.withLock { $0.append("fresh") }
            return .keepWatching
        }
        #expect(fresh.slot == stale.slot)
        #expect(fresh.generation != stale.generation)

        wheel.arm(fresh, until: .seconds(10))
        // Stale handle must be a total no-op: cannot shorten or disarm `fresh`.
        wheel.arm(stale, until: .seconds(1))
        wheel.disarm(stale)
        #expect(wheel.earliest == .seconds(10))

        let early = wheel.fireLapsed(at: .seconds(5))
        #expect(early.isEmpty)
        let due = wheel.fireLapsed(at: .seconds(10))
        #expect(!due.isEmpty)
        #expect(fired.withLock { $0 } == ["fresh"])
    }

    @Test("waitForArm wakes deterministically when a deadline moves earlier than bound")
    func waitForArmWakesWhenMovedEarlier() async throws {
        let wheel = DeadlineWheel()
        let h = wheel.register { .keepWatching }
        wheel.arm(h, until: .seconds(10))

        let woke = AsyncEventProbe<Int>(label: "wheel.woke")
        let waiter = Task {
            await wheel.waitForArm(earlierThan: .seconds(10))
            woke.record(1)
        }
        // Let the waiter register by observing an immediate arm moving earlier.
        // We arm at 4s after yielding once to enter waitForArm; even if arm runs first,
        // waitForArm checks `hasArm(earlierThan:)` under the lock so it never misses a wake!
        wheel.arm(h, until: .seconds(4))
        _ = try await woke.wait(forAtLeast: 1)
        await waiter.value
    }
}

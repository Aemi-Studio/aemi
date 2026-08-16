import Synchronization
import Testing
import AemiCore
import Observation


private struct Gadget: Equatable, Hashable, Identifiable, Sendable {
    let id: Int
    var name: String
    var count: Int

    var isNamed: Bool { !name.isEmpty }
}

@Suite("Snapshot")
struct SnapshotTests {
    @Test func forwardsStoredAndComputedMembers() {
        let gadget = Snapshot(Gadget(id: 1, name: "Sprocket", count: 3))
        #expect(gadget.name == "Sprocket")
        #expect(gadget.count == 3)
        #expect(gadget.isNamed)
    }

    @Test func conditionalConformances() {
        let a = Snapshot(Gadget(id: 1, name: "A", count: 0))
        let b = Snapshot(Gadget(id: 1, name: "A", count: 0))
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
        #expect(a.id == 1)
    }
}

@Suite("Mutable")
struct MutableTests {
    @Test func editsStayBufferedUntilCommit() {
        let source = Snapshot(Gadget(id: 7, name: "Widget", count: 2))
        let mutable = source.mutable

        mutable.name = "Renamed"
        mutable.count += 1

        // The source projection is untouched — edits only live in the buffer.
        #expect(source.name == "Widget")
        #expect(mutable.name == "Renamed")
        #expect(mutable.snapshot.count == 3)

        // Update is the only exit point.
        let updated = mutable.update()
        #expect(updated.name == "Renamed")
        #expect(updated.count == 3)
    }

    @Test func hasChangesTransitionsAndRevert() {
        let mutable = Snapshot(Gadget(id: 1, name: "Stable", count: 0)).mutable
        #expect(!mutable.hasChanges)

        mutable.count = 5
        #expect(mutable.hasChanges)

        mutable.revert()
        #expect(!mutable.hasChanges)
        #expect(mutable.count == 0)
    }

    @Test func readOnlyFallbackExposesComputedMembers() {
        let mutable = Snapshot(Gadget(id: 1, name: "X", count: 0)).mutable
        #expect(mutable.isNamed)
        #expect(mutable.snapshot.isNamed)
    }

    @Test func identifiableForwardsModelIdentity() {
        let mutable = Snapshot(Gadget(id: 42, name: "X", count: 0)).mutable
        #expect(mutable.id == 42)
    }

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    @Test func containerFieldMutationsAreInPlaceAfterDivergence() {
        // A CoW canary: counts mutations that found shared storage (the
        // situation in which a real CoW container would have to clone).
        final class Canary {}
        struct Probe: Equatable {
            static let sharedStorageMutations = Mutex(0)
            var canary = Canary()
            var count = 0

            mutating func bump() {
                if !isKnownUniquelyReferenced(&canary) {
                    Self.sharedStorageMutations.withLock { $0 += 1 }
                    canary = Canary()
                }
                count += 1
            }

            static func == (lhs: Self, rhs: Self) -> Bool { lhs.count == rhs.count }
        }
        struct Bag: Equatable {
            var probe = Probe()
        }

        Probe.sharedStorageMutations.withLock { $0 = 0 }
        let mutable = Mutable(Bag())
        for _ in 1...10 {
            mutable.probe.bump()
        }

        // Exactly one shared-storage mutation is inherent: `original` shares
        // the canary until the first edit diverges. With a get/set-only
        // subscript every bump ran on a fresh temporary copy (shared with
        // stored state), so all 10 would report shared storage; the
        // `_modify` accessor mutates the buffered field in place.
        #expect(Probe.sharedStorageMutations.withLock { $0 } == 1)
        #expect(mutable.probe.count == 10)
        #expect(mutable.hasChanges)
    }

    @Test func observationFiresOnBufferedEdit() async {
        let mutable = Snapshot(Gadget(id: 1, name: "A", count: 0)).mutable
        await confirmation("onChange fired") { fired in
            withObservationTracking {
                _ = mutable.name
            } onChange: {
                fired()
            }
            mutable.name = "B"
        }
    }
}

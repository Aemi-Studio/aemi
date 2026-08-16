import Foundation
import Testing
import AemiCore


private struct Gadget: Equatable, Hashable, Identifiable, Sendable, Codable, Comparable {
    let id: Int
    var name: String

    static func < (lhs: Gadget, rhs: Gadget) -> Bool { lhs.id < rhs.id }
}

/// A model that already carries a typed identifier owned by itself.
private struct TypedGadget: Identifiable {
    let id: Identifier<TypedGadget, Int>
    var name: String
}

private func staticType<T>(of value: T) -> T.Type { T.self }

@Suite("Typed identity")
struct TypedIdentityTests {
    @Test func wrapPathProducesPhantomTypedID() {
        let snapshot = Snapshot(Gadget(id: 7, name: "X"))
        let id = snapshot.id
        #expect(staticType(of: id) == Identifier<Gadget, Int>.self)
        #expect(id.rawValue == 7)
        #expect(id == Identifier<Gadget, Int>(7))
    }

    @Test func passThroughExposesModelsOwnIdentifier() {
        let model = TypedGadget(id: Identifier(42), name: "Y")
        let snapshot = Snapshot(model)
        let id = snapshot.id
        // No double wrapping at concrete call sites: this IS the model's ID type.
        #expect(staticType(of: id) == Identifier<TypedGadget, Int>.self)
        #expect(id == model.id)
    }

    @Test func mutableMirrorsBothPaths() {
        let wrapped = Snapshot(Gadget(id: 3, name: "A")).mutable.id
        #expect(staticType(of: wrapped) == Identifier<Gadget, Int>.self)
        #expect(wrapped.rawValue == 3)

        let passed = Snapshot(TypedGadget(id: Identifier(9), name: "B")).mutable.id
        #expect(staticType(of: passed) == Identifier<TypedGadget, Int>.self)
        #expect(passed.rawValue == 9)
    }
}

@Suite("Curated refinements")
struct RefinementTests {
    @Test func comparableForwards() {
        let a = Snapshot(Gadget(id: 1, name: "A"))
        let b = Snapshot(Gadget(id: 2, name: "B"))
        #expect(a < b)
        #expect([b, a].sorted() == [a, b])
    }

    @Test func codableRoundTripsAsBareModel() throws {
        let snapshot = Snapshot(Gadget(id: 5, name: "N"))
        let data = try JSONEncoder().encode(snapshot)
        // Encodes exactly like the bare model would — no wrapper key.
        let bare = try JSONDecoder().decode(Gadget.self, from: data)
        #expect(bare == snapshot.wrappedValue)

        let decoded = try JSONDecoder().decode(Snapshot<Gadget>.self, from: data)
        #expect(decoded == snapshot)
    }

    @Test func mutableDecodesIntoFreshBuffer() throws {
        let data = try JSONEncoder().encode(Gadget(id: 8, name: "M"))
        let mutable = try JSONDecoder().decode(Mutable<Gadget>.self, from: data)
        #expect(mutable.name == "M")
        #expect(!mutable.hasChanges)
    }

    @Test func collectionProjectsElements() {
        // Explicit types keep this under the type-check duration limit.
        let gadgets: [Gadget] = [Gadget(id: 1, name: "A"), Gadget(id: 2, name: "B"), Gadget(id: 3, name: "C")]
        let snapshots: Snapshot<[Gadget]> = Snapshot(gadgets)

        #expect(snapshots.count == 3)
        #expect(staticType(of: snapshots[1]) == Snapshot<Gadget>.self)
        #expect(snapshots[1].name == "B")
        let names: [String] = snapshots.map(\.name)
        #expect(names == ["A", "B", "C"])
        // RandomAccessCollection with forwarded O(1) index math.
        let span: Int = snapshots.distance(from: snapshots.startIndex, to: snapshots.endIndex)
        #expect(span == 3)
        #expect(snapshots.last?.name == "C")
    }

    @Test func updatingReplacesByIdentity() {
        let snapshots = Snapshot([Gadget(id: 1, name: "A"), Gadget(id: 2, name: "B")])
        let renamed = Snapshot(Gadget(id: 2, name: "B2"))

        let updated = snapshots.updating(renamed)
        let names: [String] = updated.map(\.name)
        #expect(names == ["A", "B2"])

        // Unknown id: equal result, never an insert.
        let stranger = Snapshot(Gadget(id: 99, name: "X"))
        #expect(snapshots.updating(stranger) == snapshots)
        #expect(Snapshot([Gadget]()).updating(stranger).isEmpty)
    }

    @Test func descriptions() {
        let snapshot = Snapshot(Gadget(id: 1, name: "A"))
        #expect(snapshot.debugDescription.hasPrefix("Snapshot<Gadget>("))
        #expect(snapshot.mutable.debugDescription.hasPrefix("Mutable<Gadget>("))
    }
}

import Foundation
import Testing
import AemiCore

private enum Part {}
private enum Supplier {}

/// `Identifier` forwards `_rawHashValue(seed:)` to the raw value so that a
/// `Set` or `Dictionary` never pays for a `Hasher` it does not need. `Set` and
/// `Dictionary` call `_rawHashValue`, while `hasher.combine(_:)` calls
/// `hash(into:)`. Both must agree that equal values hash equally, or a key goes
/// missing from a collection.
@Suite("Hashable witness")
struct HashWitnessTests {

    @Test(arguments: [0, 1, -1, Int.max, Int.min])
    func `equal identifiers agree on every hashing entry point`(value: Int) {
        let sut = Identifier<Part, Int>(value)
        let twin = Identifier<Part, Int>(value)

        #expect(sut == twin)
        #expect(sut.hashValue == twin.hashValue)
        #expect(sut._rawHashValue(seed: 0) == twin._rawHashValue(seed: 0))
        #expect(sut._rawHashValue(seed: 99) == twin._rawHashValue(seed: 99))

        var lhs = Hasher()
        var rhs = Hasher()
        lhs.combine(sut)
        rhs.combine(twin)
        #expect(lhs.finalize() == rhs.finalize())
    }

    @Test
    func `the seed reaches the raw value so per-process seeding survives`() {
        let sut = Identifier<Part, Int>(42)
        #expect(sut._rawHashValue(seed: 0) == 42._rawHashValue(seed: 0))
        #expect(sut._rawHashValue(seed: 7) == 42._rawHashValue(seed: 7))
        // A different seed must move the hash, or the seed is being dropped.
        #expect(sut._rawHashValue(seed: 0) != sut._rawHashValue(seed: 7))
    }

    @Test
    func `a set deduplicates by raw value and rejects an absent member`() {
        let values = Array(0..<500) + Array(0..<500)
        let sut = Set(values.map { Identifier<Part, Int>($0) })

        #expect(sut.count == 500)
        for value in values {
            #expect(sut.contains(Identifier<Part, Int>(value)))
        }
        #expect(!sut.contains(Identifier<Part, Int>(500)))
    }

    @Test
    func `a dictionary keyed by the identifier retrieves every value`() {
        var sut: [Identifier<Part, UUID>: Int] = [:]
        let keys = (0..<200).map { _ in Identifier<Part, UUID>() }
        for (offset, key) in keys.enumerated() { sut[key] = offset }

        #expect(sut.count == 200)
        for (offset, key) in keys.enumerated() {
            #expect(sut[key] == offset)
        }
    }

    /// The phantom owner types the identifier; it does not participate in the
    /// hash. Two owners sharing a raw value stay distinct types, so this can
    /// only be observed through the erased key.
    @Test
    func `erased keys of different owners with one raw value stay distinct`() {
        let part = Identifier<Part, Int>(1).erased
        let supplier = Identifier<Supplier, Int>(1).erased

        #expect(part != supplier)
        #expect(Set([part, supplier]).count == 2)
        #expect(part.belongs(to: Part.self))
        #expect(!part.belongs(to: Supplier.self))
    }

    @Test
    func `a value type whose field is an identifier hashes consistently`() {
        struct Row: Hashable {
            var id: Identifier<Part, Int>
            var name: String
        }
        let sut = Row(id: .init(7), name: "bolt")
        let twin = Row(id: .init(7), name: "bolt")

        #expect(sut == twin)
        #expect(sut.hashValue == twin.hashValue)
        #expect(Set([sut, twin]).count == 1)
    }
}

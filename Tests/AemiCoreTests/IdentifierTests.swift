import Foundation
import Testing
import AemiCore

private enum Alpha {}
private enum Beta {}

@Suite("Identifier")
struct IdentifierTests {
    @Test func phantomOwnersMakeDistinctTypes() {
        #expect(ObjectIdentifier(Identifier<Alpha, Int>.self) != ObjectIdentifier(Identifier<Beta, Int>.self))
    }

    @Test func equalityHashingAndComparability() {
        let a: Identifier<Alpha, Int> = 1
        let b = Identifier<Alpha, Int>(rawValue: 1)
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
        #expect([Identifier<Alpha, Int>(3), 1, 2].sorted() == [1, 2, 3])
    }

    @Test func identityIsSelf() {
        let id = Identifier<Alpha, String>("abc")
        #expect(id.id == id)
    }

    @Test func literalsAndDescriptions() {
        let int: Identifier<Alpha, Int> = 42
        let str: Identifier<Alpha, String> = "user-\(42)"
        #expect(int.rawValue == 42)
        #expect(str.rawValue == "user-42")
        #expect(int.description == "42")
        #expect(int.debugDescription == "Identifier<Alpha>(42)")
    }

    @Test func dynamicMemberLookupForwardsRawValueMembers() {
        let id = Identifier<Alpha, String>("abc")
        #expect(id.count == 3)
        #expect(id.isEmpty == false)
    }

    @Test func mapAndCoerced() {
        let id = Identifier<Alpha, Int>(7)
        let stringified: Identifier<Alpha, String> = id.map(String.init)
        #expect(stringified.rawValue == "7")

        let reowned: Identifier<Beta, Int> = id.coerced(to: Beta.self)
        #expect(reowned.rawValue == 7)
    }

    @Test func uuidConveniences() {
        let fresh = Identifier<Alpha, UUID>()
        #expect(!fresh.uuidString.isEmpty)

        let parsed = Identifier<Alpha, UUID>(uuidString: "11111111-1111-1111-1111-111111111111")
        #expect(parsed != nil)
        #expect(Identifier<Alpha, UUID>(uuidString: "nope") == nil)
    }

    @Test func codableRoundTripsAsBareRawValue() throws {
        let id = Identifier<Alpha, Int>(99)
        let data = try JSONEncoder().encode([id])
        #expect(String(decoding: data, as: UTF8.self) == "[99]")
        let decoded = try JSONDecoder().decode([Identifier<Alpha, Int>].self, from: data)
        #expect(decoded == [id])
    }

    // The two regressions swift-tagged's do/catch Codable strategy exists for:

    @Test func codableRespectsDateStrategies() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let id = Identifier<Alpha, Date>(Date(timeIntervalSince1970: 0))
        let data = try encoder.encode([id])
        #expect(String(decoding: data, as: UTF8.self).contains("1970-01-01T00:00:00Z"))
        let decoded = try decoder.decode([Identifier<Alpha, Date>].self, from: data)
        #expect(decoded == [id])
    }

    @Test func codableHandlesOptionalNull() throws {
        let decoded = try JSONDecoder().decode(
            [Identifier<Alpha, String?>].self,
            from: Data("[null, \"x\"]".utf8)
        )
        #expect(decoded.count == 2)
        #expect(decoded[0].rawValue == nil)
        #expect(decoded[1].rawValue == "x")
    }

    @Test func mixedOwnerDictionaryKeepsEntitiesDistinct() {
        let shared = UUID()
        let partID = Identifier<Alpha, UUID>(shared)
        let orderID = Identifier<Beta, UUID>(shared)

        // Same raw UUID, two owners: two distinct keys in one dictionary.
        var labels: [AnyIdentifier<UUID>: String] = [:]
        labels[partID.erased] = "part"
        labels[orderID.erased] = "order"

        #expect(labels.count == 2)
        #expect(labels[partID.erased] == "part")
        #expect(labels[orderID.erased] == "order")
        #expect(partID.erased.belongs(to: Alpha.self))
        #expect(!partID.erased.belongs(to: Beta.self))
    }

    @Test func anyHashableAlsoWorksAsMixedKey() {
        // The zero-code route: AnyHashable never equates distinct dynamic
        // types, so mixed identifier keys stay distinct. Trade-offs vs
        // AnyIdentifier: boxing, no Sendable, raw type erased, no owner query.
        let shared = UUID()
        var labels: [AnyHashable: String] = [:]
        labels[Identifier<Alpha, UUID>(shared)] = "part"
        labels[Identifier<Beta, UUID>(shared)] = "order"

        #expect(labels.count == 2)
        #expect(labels[Identifier<Alpha, UUID>(shared)] == "part")
    }

    @Test func dictionaryKeysEncodeAsObjects() throws {
        let dict: [Identifier<Alpha, String>: Int] = ["a": 1]
        let data = try JSONEncoder().encode(dict)
        #expect(String(decoding: data, as: UTF8.self) == #"{"a":1}"#)
        let decoded = try JSONDecoder().decode([Identifier<Alpha, String>: Int].self, from: data)
        #expect(decoded == dict)
    }
}

import AemiKernel
import AemiTestKit
import Testing

/// `HashIndex` against a dictionary, with keys kept by the test, through growth and under a hash that collides on purpose.
struct HashIndexTests {
    @Test func `finds what a dictionary finds, through growth`() {
        let keys = (0 ..< 5000).map { "key-\($0 % 3000)" }
        let hash = KeyedHash(k0: 3, k1: 4)
        var index = HashIndex()
        var stored: [String] = []
        var reference: [String: Int32] = [:]
        for key in keys {
            let found = index.findOrInsert(Int32(stored.count), hash: hash.hash(Array(key.utf8))) {
                stored[Int($0)] == key
            }
            #expect(found == reference[key])
            if found == nil {
                reference[key] = Int32(stored.count)
                stored.append(key)
            }
        }
        #expect(index.count == 3000)
        for (key, value) in reference {
            #expect(index.find(hash: hash.hash(Array(key.utf8))) { stored[Int($0)] == key } == value)
        }
        #expect(index.find(hash: hash.hash(Array("absent".utf8))) { stored[Int($0)] == "absent" } == nil)
    }

    @Test func `values sharing one hash are told apart by the caller's equality`() {
        var index = HashIndex(capacity: 4)
        for value in Int32(0) ..< 100 { index.insert(value, hash: 42) }
        for value in Int32(0) ..< 100 { #expect(index.find(hash: 42) { $0 == value } == value) }
        #expect(index.find(hash: 42) { $0 == 100 } == nil)
        #expect(index.find(hash: 43) { _ in true } == nil)
    }
}

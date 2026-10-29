import AemiKernel
import Testing

/// `ByteBitmap` and `SparseSet`, promoted from AemiRegex (aemi ADR 0018).
struct ByteBitmapAndSparseSetTests {
    @Test func `a byte bitmap holds exactly the ranges inserted, across every word`() {
        var set = ByteBitmap()
        set.insert(0x30 ... 0x39)
        set.insert(0x3F ... 0x40)
        set.insert(0x7F ... 0x80)
        set.insert(0xFF ... 0xFF)
        let expected = Set((0x30 ... 0x39) + [0x3F, 0x40, 0x7F, 0x80, 0xFF].map { $0 })
        for byte in 0 ... 255 { #expect(set.contains(UInt8(byte)) == expected.contains(byte), "\(byte)") }
        #expect(set.members == expected.sorted().map { UInt8($0) })
        var other = ByteBitmap()
        other.insert(0x00 ... 0x00)
        other.formUnion(set)
        #expect(other.members == [0] + set.members)
        #expect(ByteBitmap().members.isEmpty)
    }

    @Test func `a sparse set keeps insertion order, answers membership, and clears in one step`() {
        var set = SparseSet(capacity: 64)
        #expect(set.isEmpty)
        for value in [5, 63, 0, 17] where !set.contains(value) { set.insert(value) }
        #expect(set.count == 4 && Array(set.dense.prefix(set.count)) == [5, 63, 0, 17])
        for value in 0 ..< 64 { #expect(set.contains(value) == [5, 63, 0, 17].contains(value), "\(value)") }
        set.removeAll()
        #expect(set.isEmpty && !set.contains(5) && !set.contains(0))
        set.insert(9)
        #expect(set.contains(9) && !set.contains(5), "stale slots answer no after a clear")
    }
}

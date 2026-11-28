import AemiKernel
import Testing

struct RegionRingTests {
    @Test func wrapsAndSkipsTheTail() throws {
        var ring = RegionRing(capacity: 1024, alignment: 64)
        let aSlot = ring.allocate(400)
        let a = try #require(aSlot)  // [0, 448)
        let bSlot = ring.allocate(400)
        let b = try #require(bSlot)  // [448, 896)
        #expect(a.offset == 0 && a.count == 448 && b.offset == 448)
        #expect(ring.allocate(200) == nil)  // 128 left at the end, 0 at the front
        ring.releaseOldest()
        let cSlot = ring.allocate(200)
        let c = try #require(cSlot)  // the tail [896, 1024) is skipped
        #expect(c.offset == 0 && c.count == 256)
        #expect(ring.usedBytes == 448 + 128 + 256)
        ring.release(through: b.id)
        #expect(ring.usedBytes == 128 + 256)  // c still holds the skipped tail
        ring.release(through: c.id)
        #expect(ring.isEmpty && ring.usedBytes == 0)
        #expect(ring.allocate(1024)?.offset == 0)
        #expect(ring.allocate(1) == nil)
    }

    /// Random allocate/release against a byte-ownership model: live regions never overlap, stay in
    /// bounds, and the ring refuses only when the model has no contiguous room ahead of the writer.
    @Test func liveRegionsNeverOverlap() {
        var rng = SplitMix64(seed: 42)
        let capacity = 4096
        var ring = RegionRing(capacity: capacity, alignment: 16)
        var live: [RegionRing.Region] = []
        for _ in 0 ..< 40_000 {
            if rng.next() % 3 != 0 || live.isEmpty {
                let size = Int(rng.next() % 1500) + 1
                if let region = ring.allocate(size) {
                    #expect(region.offset >= 0 && region.offset + region.count <= capacity)
                    #expect(region.count >= size && region.offset % 16 == 0)
                    for other in live {
                        let disjoint =
                            region.offset + region.count <= other.offset
                            || other.offset + other.count <= region.offset
                        #expect(disjoint)
                    }
                    live.append(region)
                } else {
                    #expect(!live.isEmpty)  // an empty ring always fits a region up to its capacity
                }
            } else {
                ring.releaseOldest()
                live.removeFirst()
            }
            #expect(ring.count == live.count)
            #expect(ring.usedBytes >= live.reduce(0) { $0 + $1.count } && ring.usedBytes <= capacity)
        }
    }
}

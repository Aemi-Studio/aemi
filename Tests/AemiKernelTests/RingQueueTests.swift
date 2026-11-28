import AemiKernel
import Testing

struct RingQueueTests {
    /// Random operations against `Array` as the reference model, across many wrap-arounds and growths.
    @Test func matchesAnArrayModel() {
        var rng = SplitMix64(seed: 0x5EED)
        var ring = RingQueue<Int>()
        var model: [Int] = []
        for step in 0 ..< 50_000 {
            switch rng.next() % 9 {
                case 0 ... 3:
                    ring.append(step)
                    model.append(step)
                case 4, 5:
                    #expect(ring.popFirst() == (model.isEmpty ? nil : model.removeFirst()))
                case 6:
                    #expect(ring.popLast() == model.popLast())
                case 7 where !model.isEmpty:
                    let at = Int(rng.next() % UInt64(model.count))
                    #expect(ring.remove(at: at) == model.remove(at: at))
                default:
                    if !model.isEmpty {
                        let at = Int(rng.next() % UInt64(model.count))
                        ring[at] = -step
                        model[at] = -step
                    }
            }
            #expect(ring.count == model.count)
        }
        #expect(Array(ring) == model)
    }

    @Test func steadyStateDoesNotGrow() {
        var ring = RingQueue<Int>(minimumCapacity: 5)
        #expect(ring.capacity == 8)
        for value in 0 ..< 10_000 {
            ring.append(value)
            if ring.count > 6 { _ = ring.popFirst() }
        }
        #expect(ring.capacity == 8)
        #expect(Array(ring) == Array(9994 ..< 10_000))
    }

    @Test func removeFirstWhereAndEquality() {
        var ring: RingQueue = [1, 2, 3, 4]
        #expect(ring.removeFirst { $0.isMultiple(of: 2) } == 2)
        #expect(ring.removeFirst { $0 > 9 } == nil)
        #expect(ring == [1, 3, 4])
        ring.removeAll()
        #expect(ring.isEmpty && ring.capacity == 4)
    }
}

import AemiKernel
import Testing

struct ByteQueueTests {
    @Test func readsInOrderAcrossAppendsAndConsumes() {
        var queue = ByteQueue(compactionThreshold: 4)
        queue.append(contentsOf: [1, 2, 3, 4, 5])
        #expect(queue.take(2) == [1, 2])
        queue.append(contentsOf: [6, 7])
        #expect(Array(queue.readable) == [3, 4, 5, 6, 7])
        #expect(queue[0] == 3 && queue[4] == 7)
        let sum = queue.withUnsafeReadableBytes { raw in raw.reduce(0) { $0 + Int($1) } }
        #expect(sum == 25)
        queue.consume(5)
        #expect(queue.isEmpty)
    }

    @Test func drainingKeepsCapacityAndResetsTheCursor() {
        var queue = ByteQueue()
        queue.append(contentsOf: [UInt8](repeating: 9, count: 4096))
        let capacity = queue.capacity
        queue.consume(4096)
        #expect(queue.isEmpty && queue.capacity == capacity)
        queue.append(contentsOf: [1, 2, 3])
        #expect(Array(queue.readable) == [1, 2, 3])
    }

    /// A dead prefix is shifted out only once it reaches the threshold and outweighs the live bytes,
    /// so a parser that always leaves a partial message cannot grow the storage without bound.
    @Test func compactionBoundsTheStorage() {
        var queue = ByteQueue(compactionThreshold: 64)
        var expected: [UInt8] = []
        for round in 0 ..< 10_000 {
            let chunk = (0 ..< 37).map { UInt8(truncatingIfNeeded: round &+ $0) }
            queue.append(contentsOf: chunk)
            expected.append(contentsOf: chunk)
            let keep = round % 5  // leave a partial "message" behind
            let consumed = queue.count - keep
            queue.consume(consumed)
            expected.removeFirst(consumed)
            #expect(queue.capacity <= 4 * (64 + 37 + 8))
        }
        #expect(Array(queue.readable) == expected)
    }

    @Test func storagePastTheRetainedLimitIsReleased() {
        var queue = ByteQueue(retainedCapacityLimit: 1024)
        queue.append(contentsOf: [UInt8](repeating: 1, count: 1 << 20))
        queue.consume((1 << 20) - 10)
        #expect(queue.count == 10 && queue.capacity < 1 << 20)
        queue.consume(10)
        #expect(queue.capacity <= 1024)
    }

    @Test func typedThrowsPassThrough() {
        struct Stop: Error {}
        var queue = ByteQueue()
        queue.append(7)
        #expect(throws: Stop.self) { try queue.withUnsafeReadableBytes { _ throws(Stop) in throw Stop() } }
    }
}

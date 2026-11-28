import AemiKernel
import AemiTestKit
import Testing

// Steady-state guards for the queues: once warmed to their high-water mark, appending, reading and
// removing must not allocate, also in a -Onone build where generic code runs unspecialized (a
// `Collection` default reached through the witness table allocated there). Each guard runs in its
// own child process, as the Base64 guards do, keeping the fewest allocations over several runs.

private func requireAllocations(atMost limit: Int, _ what: String, _ body: () -> Void) {
    guard allocationCountingAvailable else {
        body()
        return
    }
    body()
    var fewest = Int.max
    for _ in 0 ..< 50 { fewest = Swift.min(fewest, mallocDelta(body) ?? 0) }
    if fewest > limit {
        print("\(what): measured \(fewest) allocation(s), expected at most \(limit)")
        fatalError("allocation guard failed: \(what)")
    }
}

struct QueueAllocationTests {
    @Test func ringQueueSteadyStateAllocatesNothing() async {
        await #expect(processExitsWith: .success) {
            var ring = RingQueue<String>()
            for index in 0 ..< 100 { ring.append("entry-\(index)-with-a-heap-backed-name") }
            let element = "an-element-long-enough-to-live-on-the-heap"
            requireAllocations(atMost: 0, "RingQueue churn") {
                _ = ring.popFirst()
                ring.append(element)
                _ = ring.first
                _ = ring.last
                _ = ring[50]
                _ = ring.count
            }
        }
    }

    @Test func byteQueueSteadyStateAllocatesNothing() async {
        await #expect(processExitsWith: .success) {
            var queue = ByteQueue(compactionThreshold: 256)
            let chunk = [UInt8](repeating: 7, count: 1500)
            for _ in 0 ..< 10 {
                queue.append(contentsOf: chunk)
                queue.consume(queue.count - 3)
            }
            requireAllocations(atMost: 0, "ByteQueue append/consume") {
                queue.append(contentsOf: chunk)
                _ = queue.withUnsafeReadableBytes { $0.count }
                queue.consume(queue.count - 3)
            }
        }
    }

    @Test func regionRingSteadyStateAllocatesNothing() async {
        await #expect(processExitsWith: .success) {
            var ring = RegionRing(capacity: 1 << 20)
            for _ in 0 ..< 64 { _ = ring.allocate(10_000) }
            requireAllocations(atMost: 0, "RegionRing allocate/release") {
                ring.releaseOldest()
                _ = ring.allocate(10_000)
            }
        }
    }
}

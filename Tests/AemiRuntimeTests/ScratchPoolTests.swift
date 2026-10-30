import AemiRuntime
import Synchronization
import Testing

/// `ScratchPool`, promoted from AemiRegex (aemi ADR 0018): values are reused, made only when none is free, and each is used by one
/// caller at a time.
struct ScratchPoolTests {
    @Test func `a value is reused, with what the last user left in it`() {
        let made = Atomic(0)
        let pool = ScratchPool<[Int]> {
            made.add(1, ordering: .relaxed)
            return []
        }
        pool.withScratch { $0.append(1) }
        let seen = pool.withScratch { scratch -> [Int] in
            scratch.append(2)
            return scratch
        }
        #expect(seen == [1, 2])
        #expect(made.load(ordering: .relaxed) == 1)
    }

    /// The point of the pool is to keep large working memory between calls: a value handed out must be the stored one, mutated in
    /// place, never a copy (a copy would also cost every caller a retain and release of each buffer it holds).
    @Test func `the value is lent in place, so its buffers are never copied`() {
        let pool = ScratchPool<[Int]> { [Int](repeating: 0, count: 1_024) }
        let first = pool.withScratch { scratch in
            scratch[0] = 1
            return scratch.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) }
        }
        let second = pool.withScratch { scratch in
            scratch[1] = 2
            return scratch.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) }
        }
        #expect(first == second, "the buffer moved, so the value was copied on the way in or out")
    }

    @Test func `concurrent users each get their own value, and no more are made than were in use at once`() async {
        let made = Atomic(0)
        let inUse = Atomic(0)
        let peak = Atomic(0)
        let pool = ScratchPool<Int> {
            made.add(1, ordering: .relaxed)
            return 0
        }
        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 64 {
                group.addTask {
                    // Counted around the call, not inside the body: the pool holds a value from taking it to giving it back,
                    // a window the body does not cover. Counted inside, a user between its body and its return made the next
                    // user's new value look unneeded (26 runs in 30 failed so).
                    let now = inUse.add(1, ordering: .relaxed).newValue
                    _ = peak.max(now, ordering: .relaxed)
                    pool.withScratch { value in
                        // A value is someone else's only if two users hold it: each increments and checks its own count.
                        value += 1
                        let mine = value
                        for _ in 0 ..< 1_000 { _ = mine }
                        #expect(value == mine, "another user changed this value")
                    }
                    inUse.subtract(1, ordering: .relaxed)
                }
            }
        }
        #expect(made.load(ordering: .relaxed) <= peak.load(ordering: .relaxed))
    }
}

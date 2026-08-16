import AemiKernel
import Testing

struct BoundedTopKTests {
    /// Reference: the K smallest `(dist, idx)` pairs in the pinned total order are exactly the first
    /// K after sorting ALL pairs by `(dist, idx)` ascending — because `offer` is fed in idx order, so
    /// the strict-distance admission keeps the smallest-idx members at the boundary distance.
    private func reference(_ pairs: [(dist: Int, idx: Int)], _ k: Int) -> [(dist: Int, idx: Int)] {
        guard k > 0 else { return [] }
        let sorted = pairs.sorted { $0.dist != $1.dist ? $0.dist < $1.dist : $0.idx < $1.idx }
        return Array(sorted.prefix(k))
    }

    private func run(_ dists: [Int], k: Int) -> [(dist: Int, idx: Int)] {
        var heap = BoundedTopK(capacity: k)
        for (i, d) in dists.enumerated() { heap.offer(dist: d, idx: i) }
        return heap.sortedAscending()
    }

    private func expectEqual(_ got: [(dist: Int, idx: Int)], _ want: [(dist: Int, idx: Int)]) {
        #expect(got.count == want.count)
        for (a, b) in zip(got, want) {
            #expect(a.dist == b.dist)
            #expect(a.idx == b.idx)
        }
    }

    @Test func emptyAndDegenerateCapacities() {
        expectEqual(run([3, 1, 2], k: 0), [])
        expectEqual(run([], k: 5), [])
        // K larger than n keeps everything, fully ordered.
        expectEqual(run([3, 1, 2], k: 10), [(1, 1), (2, 2), (3, 0)])
    }

    @Test func tiesKeepSmallestIndexAtBoundary() {
        // Three equal distances, capacity 2 → keep idx 0 and 1 (first-arriving), reject idx 2.
        expectEqual(run([5, 5, 5], k: 2), [(5, 0), (5, 1)])
        // A strictly smaller distance evicts the worst even when distances otherwise tie.
        expectEqual(run([3, 3, 2], k: 2), [(2, 2), (3, 0)])
    }

    @Test func ascendingByDistThenIdx() {
        let dists = [9, 1, 5, 1, 7, 3]
        expectEqual(run(dists, k: 3), [(1, 1), (1, 3), (3, 5)])
    }

    @Test func matchesBruteForceOracleOverRandomInputs() {
        // Deterministic LCG so the fuzz is reproducible; exercise many (n, K, distance-range) combos
        // including heavy ties (small range) and the boundary K == n / K > n.
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
        for n in [0, 1, 2, 7, 16, 50, 200] {
            for k in [1, 2, 5, 16, 64, 256] {
                for range in [1, 3, 8, 64] {
                    let dists = (0 ..< n).map { _ in next(range) }
                    var pairs: [(dist: Int, idx: Int)] = []
                    for (i, d) in dists.enumerated() { pairs.append((dist: d, idx: i)) }
                    expectEqual(run(dists, k: k), reference(pairs, Swift.min(k, n)))
                }
            }
        }
    }
}

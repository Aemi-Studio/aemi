import AemiKernel
import AemiTestKit
import Testing

@Suite("Graphs and SplitMix64")
struct GraphTests {
    @Test func `SplitMix64 gives the published stream, and SeededRNG is the same stream`() {
        var generator = SplitMix64(seed: 0)
        #expect(
            (0 ..< 4).map { _ in generator.next() } == [
                0xE220_A839_7B1D_CDAF, 0x6E78_9E6A_A1B9_65F4, 0x06C4_5D18_8009_454F, 0xF88B_B8A8_724C_81EC
            ]
        )
        var mine = SplitMix64(seed: 0xDEAD_BEEF)
        var kit = SeededRNG(seed: 0xDEAD_BEEF)
        #expect((0 ..< 1000).allSatisfy { _ in mine.next() == kit.next() })
    }

    /// The components by reachability: a and b share one when each reaches the other.
    private static func naive(_ adjacency: [[Int]]) -> Set<Set<Int>> {
        let count = adjacency.count
        var reach = [[Bool]](repeating: [Bool](repeating: false, count: count), count: count)
        for start in 0 ..< count {
            var pending = [start]
            reach[start][start] = true
            while let node = pending.popLast() {
                for next in adjacency[node] where !reach[start][next] {
                    reach[start][next] = true
                    pending.append(next)
                }
            }
        }
        var components: Set<Set<Int>> = []
        for node in 0 ..< count {
            components.insert(Set((0 ..< count).filter { reach[node][$0] && reach[$0][node] }))
        }
        return components
    }

    @Test func `components equal the reachability reference on generated graphs, in reverse topological order`() {
        var random = SeededRNG(seed: 27)
        for round in 0 ..< 300 {
            let count = 1 + random.uniform(24)
            let edges = random.uniform(count * 3)
            var adjacency = [[Int]](repeating: [], count: count)
            for _ in 0 ..< edges { adjacency[random.uniform(count)].append(random.uniform(count)) }
            let found = StronglyConnectedComponents.find(nodeCount: count, adjacency: adjacency)
            #expect(Set(found.map(Set.init)) == Self.naive(adjacency), "round \(round)")
            #expect(found.map(\.count).reduce(0, +) == count, "round \(round)")
            // Tarjan completes a component after every component it reaches: no edge leads to a later one.
            var position = [Int](repeating: 0, count: count)
            for (at, component) in found.enumerated() { for node in component { position[node] = at } }
            #expect(
                (0 ..< count).allSatisfy { node in adjacency[node].allSatisfy { position[$0] <= position[node] } },
                "round \(round)"
            )
        }
    }

    @Test func `a chain and a ring of a million nodes need no call stack`() {
        struct Ring: Digraph {
            let nodeCount: Int
            let closed: Bool
            func successorCount(of node: Int) -> Int { closed || node + 1 < nodeCount ? 1 : 0 }
            func successor(of node: Int, at position: Int) -> Int { (node + 1) % nodeCount }
        }
        let chain = StronglyConnectedComponents.find(in: Ring(nodeCount: 1_000_000, closed: false))
        #expect(chain.count == 1_000_000)
        let ring = StronglyConnectedComponents.find(in: Ring(nodeCount: 1_000_000, closed: true))
        #expect(ring.count == 1 && ring[0].count == 1_000_000)
    }

    @Test func `disjoint sets agree with a naive labelling, and a long chain of unions needs no call stack`() {
        var random = SeededRNG(seed: 31)
        for _ in 0 ..< 200 {
            let count = 1 + random.uniform(40)
            var sets = DisjointSets(count: count)
            var label = Array(0 ..< count)
            for _ in 0 ..< random.uniform(count * 2) {
                let a = random.uniform(count)
                let b = random.uniform(count)
                let joined = sets.union(a, b)
                let (from, into) = (label[b], label[a])
                #expect(joined == (from != into))
                for index in label.indices where label[index] == from { label[index] = into }
            }
            for a in 0 ..< count {
                for b in 0 ..< count { #expect((sets.find(a) == sets.find(b)) == (label[a] == label[b])) }
            }
        }
        var long = DisjointSets(count: 1_000_000)
        for index in 1 ..< 1_000_000 { long.union(index - 1, index) }
        #expect(long.find(999_999) == long.find(0))
    }
}

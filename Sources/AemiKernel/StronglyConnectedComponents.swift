/// A directed graph as Tarjan's algorithm reads it: its nodes `0 ..< nodeCount`, and each node's successors by position. Conform a
/// graph too large to hold (a state space) by computing successors in place; `[[Int]]` conforms as an adjacency list.
public protocol Digraph {
    var nodeCount: Int { get }
    func successorCount(of node: Int) -> Int
    func successor(of node: Int, at position: Int) -> Int
}

extension Array: Digraph where Element == [Int] {
    @inlinable public var nodeCount: Int { count }
    @inlinable public func successorCount(of node: Int) -> Int { self[node].count }
    @inlinable public func successor(of node: Int, at position: Int) -> Int { self[node][position] }
}

/// Tarjan's strongly connected components, iterative: an explicit frame stack, so a chain of a million nodes collapsing into one
/// component costs no call stack. O(V + E). Components come in the order Tarjan completes them (no edge leads from a component to a
/// later one), each member in the order it leaves the stack, so the result is deterministic for a given graph.
public enum StronglyConnectedComponents {
    /// The components of the graph whose node `n` has the successors `adjacency[n]`.
    @inlinable
    public static func find(nodeCount: Int, adjacency: [[Int]]) -> [[Int]] {
        precondition(nodeCount == adjacency.count, "one adjacency list per node")
        return find(in: adjacency)
    }

    /// The components of `graph`.
    @inlinable
    public static func find(in graph: some Digraph) -> [[Int]] {
        let nodeCount = graph.nodeCount
        var index = [Int](repeating: -1, count: nodeCount)
        var lowlink = [Int](repeating: 0, count: nodeCount)
        var onStack = [Bool](repeating: false, count: nodeCount)
        var stack: [Int] = []
        var counter = 0
        var components: [[Int]] = []
        var frames: [(node: Int, next: Int)] = []
        for start in 0 ..< nodeCount where index[start] == -1 {
            frames.append((start, 0))
            index[start] = counter
            lowlink[start] = counter
            counter += 1
            stack.append(start)
            onStack[start] = true
            while let frame = frames.last {
                let node = frame.node
                if frame.next < graph.successorCount(of: node) {
                    let child = graph.successor(of: node, at: frame.next)
                    frames[frames.count - 1].next += 1
                    if index[child] == -1 {
                        index[child] = counter
                        lowlink[child] = counter
                        counter += 1
                        stack.append(child)
                        onStack[child] = true
                        frames.append((child, 0))
                    } else if onStack[child] {
                        lowlink[node] = min(lowlink[node], index[child])
                    }
                } else {
                    frames.removeLast()
                    if let parent = frames.last?.node { lowlink[parent] = min(lowlink[parent], lowlink[node]) }
                    if lowlink[node] == index[node] {
                        var component: [Int] = []
                        while true {
                            let member = stack.removeLast()
                            onStack[member] = false
                            component.append(member)
                            if member == node { break }
                        }
                        components.append(component)
                    }
                }
            }
        }
        return components
    }
}

/// Disjoint sets (union-find) over `0 ..< count`, union by rank and path halving: near-constant time per operation, and `find` is a
/// loop, so no chain of unions can deepen a call stack.
public struct DisjointSets: Sendable {
    @usableFromInline var parent: [Int]
    @usableFromInline var rank: [UInt8]

    public init(count: Int) {
        parent = Array(0 ..< count)
        rank = [UInt8](repeating: 0, count: count)
    }

    public var count: Int { parent.count }

    /// The representative of `element`'s set.
    @inlinable
    public mutating func find(_ element: Int) -> Int {
        var node = element
        while parent[node] != node {
            parent[node] = parent[parent[node]]
            node = parent[node]
        }
        return node
    }

    /// Joins the sets of `a` and `b`; false when they were one already.
    @inlinable
    @discardableResult
    public mutating func union(_ a: Int, _ b: Int) -> Bool {
        var rootA = find(a)
        var rootB = find(b)
        guard rootA != rootB else { return false }
        if rank[rootA] < rank[rootB] { swap(&rootA, &rootB) }
        parent[rootB] = rootA
        if rank[rootA] == rank[rootB] { rank[rootA] &+= 1 }
        return true
    }
}

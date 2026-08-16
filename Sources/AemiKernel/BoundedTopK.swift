/// A fixed-capacity selection of the K SMALLEST `(dist, idx)` pairs — a bounded binary MAX-heap whose
/// root is the worst kept candidate (largest distance, ties broken by largest index). Family-wide
/// because the semantic-search tier selects the K nearest packed-bit vectors by Hamming distance
/// (``Popcount``), and a bounded heap caps that scan at O(n log K) / O(K) memory rather than sorting
/// all n.
///
/// The ordering is the exact integer total order the JS reference uses, so the admitted set AND its
/// final order match bit-for-bit (apple-docs `shortlistByHamming` in `src/search/semantic.js`):
///   - admit a new `(d, i)` iff `d < root distance` (strict) once full;
///   - sift up while a parent is smaller by `(dist, idx)` — stop when
///     `heapDist[p] > d || (heapDist[p] == d && heapIdx[p] > i)`;
///   - sift down toward the LARGER child by `(dist, idx)`;
///   - ``sortedAscending()`` returns the kept pairs ascending by `(dist, idx)`
///     (the JS `a.dist - b.dist || a.idx - b.idx`).
///
/// This is deliberately specialized to two `Int` keys with that pinned tie-break — it is the
/// byte-parity primitive, not a general container. For ordinary bounded top-K with no parity contract,
/// prefer `apple/swift-collections`' `Heap`.
public struct BoundedTopK {
    @usableFromInline var heapDist: [Int]
    @usableFromInline var heapIdx: [Int]
    @usableFromInline var size: Int
    @usableFromInline let capacity: Int

    /// A heap that keeps at most `capacity` of the smallest `(dist, idx)` pairs. A non-positive
    /// `capacity` keeps nothing (every ``offer(dist:idx:)`` is a no-op).
    public init(capacity: Int) {
        self.capacity = capacity
        let slots = Swift.max(capacity, 0)
        heapDist = [Int](repeating: 0, count: slots)
        heapIdx = [Int](repeating: 0, count: slots)
        size = 0
    }

    /// The number of pairs currently kept (≤ `capacity`).
    @inlinable public var count: Int { size }

    /// Offer one `(dist, idx)` pair. Kept iff fewer than `capacity` are held, or `dist` is strictly
    /// smaller than the current worst kept distance (ties on the worst stay out). `@inlinable` so the
    /// per-element call inlines into a tight scan under cross-module optimization.
    @inlinable
    public mutating func offer(dist d: Int, idx i: Int) {
        let cap = capacity
        if size < cap {
            // Sift up: bubble (d, i) toward the root while parents are smaller by (dist, idx).
            var c = size
            size += 1
            while c > 0 {
                let p = (c - 1) >> 1
                if heapDist[p] > d || (heapDist[p] == d && heapIdx[p] > i) { break }
                heapDist[c] = heapDist[p]
                heapIdx[c] = heapIdx[p]
                c = p
            }
            heapDist[c] = d
            heapIdx[c] = i
        } else if cap > 0, d < heapDist[0] {
            // Replace the root, then sift down toward the larger child by (dist, idx).
            var c = 0
            while true {
                let l = 2 * c + 1
                let r = l + 1
                var bigDist = d
                var bigIdx = i
                var big = -1
                if l < cap, heapDist[l] > bigDist || (heapDist[l] == bigDist && heapIdx[l] > bigIdx) {
                    big = l
                    bigDist = heapDist[l]
                    bigIdx = heapIdx[l]
                }
                if r < cap, heapDist[r] > bigDist || (heapDist[r] == bigDist && heapIdx[r] > bigIdx) {
                    big = r
                }
                if big == -1 { break }
                heapDist[c] = heapDist[big]
                heapIdx[c] = heapIdx[big]
                c = big
            }
            heapDist[c] = d
            heapIdx[c] = i
        }
    }

    /// The kept pairs, ascending by `(dist, idx)` — the final shortlist order.
    public func sortedAscending() -> [(dist: Int, idx: Int)] {
        var out: [(dist: Int, idx: Int)] = []
        out.reserveCapacity(size)
        for r in 0 ..< size { out.append((dist: heapDist[r], idx: heapIdx[r])) }
        out.sort { lhs, rhs in lhs.dist != rhs.dist ? lhs.dist < rhs.dist : lhs.idx < rhs.idx }
        return out
    }
}

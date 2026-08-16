/// Generic text algorithms. Reference-neutral and stdlib-only: the caller chooses the element
/// granularity (UTF-16 code units, Unicode scalars, bytes, characters), so domain-specific parity
/// (e.g. JS string indexing) lives at the call site, not here.
///
/// All members are pure free functions over value types with no shared mutable state, so they are
/// inherently `Sendable`-safe and `nonisolated`: call them from any actor or thread, and fan a batch
/// out across a `TaskGroup` / `concurrentPerform` freely. (Parallelizing very small inputs can lose
/// to scheduling overhead — measure the batch before fanning out.)
public enum AemiText {
    /// Levenshtein edit distance with an early exit — adaptive over input size and the distance bound.
    ///
    /// Returns the exact distance (the minimum single-element insertions, deletions, and
    /// substitutions to turn `a` into `b`) when it is `≤ maxDistance`, otherwise `maxDistance + 1`
    /// (saturating). With the default `maxDistance` the exact distance is always returned.
    ///
    /// Dispatch: when the bound is tight relative to the inputs (`2·maxDistance + 1 < b.count`) the
    /// O(`a.count`·`maxDistance`) **banded** matrix is used; otherwise the O(`a.count`·`b.count`)
    /// **full** matrix (which also serves the unbounded case). Both honor the same early-exit contract.
    public static func editDistance<Element: Equatable>(
        _ a: [Element], _ b: [Element], maxDistance: Int = .max
    ) -> Int {
        let m = a.count
        let n = b.count
        if abs(m - n) > maxDistance { return maxDistance + 1 }
        if m == 0 { return n <= maxDistance ? n : maxDistance + 1 }
        if n == 0 { return m <= maxDistance ? m : maxDistance + 1 }
        // Banded only when the band (width 2·k+1) is strictly narrower than the row, and the row is
        // long enough that skipping out-of-band cells outweighs the band's boundary bookkeeping. The
        // size threshold is set from the benchmark crossover (see Benchmarks/AemiFoundationSuite).
        if maxDistance < (n - 1) / 2, n >= bandedMinRowWidth {
            return editDistanceBanded(a, b, maxDistance: maxDistance)
        }
        return editDistanceFull(a, b, maxDistance: maxDistance)
    }

    /// Row width below which the full matrix is used even for a tight bound (banded bookkeeping does
    /// not pay on tiny rows). Benchmarked crossover: banded already wins ~2× at width 16 and far more
    /// above it, so 16 is the floor (below it the absolute cost is negligible either way).
    @usableFromInline static let bandedMinRowWidth = 16

    /// Full two-row Levenshtein matrix with the early-exit bound. Exact when `maxDistance == .max`.
    public static func editDistanceFull<Element: Equatable>(
        _ a: [Element], _ b: [Element], maxDistance: Int = .max
    ) -> Int {
        let m = a.count
        let n = b.count
        if abs(m - n) > maxDistance { return maxDistance + 1 }
        if m == 0 { return n <= maxDistance ? n : maxDistance + 1 }
        if n == 0 { return m <= maxDistance ? m : maxDistance + 1 }
        // Drive the two rolling rows with the shorter input so the scratch block and the inner loop
        // are O(min(m, n)). Edit distance is symmetric, so orienting the matrix this way is exact.
        let (rows, cols) = m >= n ? (a, b) : (b, a)
        return rows.withUnsafeBufferPointer { rowBuf in
            cols.withUnsafeBufferPointer { colBuf in
                fullMatrix(rows: rowBuf, cols: colBuf, maxDistance: maxDistance)
            }
        }
    }

    /// Core of ``editDistanceFull(_:_:maxDistance:)`` over borrowed buffers. The two rolling rows of
    /// `cols.count + 1` cells share one `withUnsafeTemporaryAllocation` block (stack-allocated for
    /// typical sizes, heap for large), and every cell is reached through unchecked buffer subscripts,
    /// so the O(`rows.count`·`cols.count`) loop carries no per-cell bounds check and allocates no rows.
    private static func fullMatrix<Element: Equatable>(
        rows: UnsafeBufferPointer<Element>, cols: UnsafeBufferPointer<Element>, maxDistance: Int
    ) -> Int {
        let m = rows.count
        let n = cols.count
        return withUnsafeTemporaryAllocation(of: Int.self, capacity: 2 * (n + 1)) { scratch in
            var prev = 0
            var cur = n + 1
            for j in 0 ... n { scratch[j] = j }
            for i in 1 ... m {
                scratch[cur] = i
                var rowMin = i
                let ai = rows[i - 1]
                for j in 1 ... n {
                    let value: Int
                    if ai == cols[j - 1] {
                        value = scratch[prev + j - 1]
                    } else {
                        let deletion = scratch[prev + j]
                        let insertion = scratch[cur + j - 1]
                        let substitution = scratch[prev + j - 1]
                        value = 1 + Swift.min(deletion, insertion, substitution)
                    }
                    scratch[cur + j] = value
                    if value < rowMin { rowMin = value }
                }
                if rowMin > maxDistance { return maxDistance + 1 }
                swap(&prev, &cur)
            }
            // Saturate at `maxDistance + 1`: the row-minimum early-exit can miss a final distance that
            // only exceeds the bound on the last column, so clamp for a well-defined bounded contract
            // (matching the banded path). When `maxDistance == .max` the comparison is never true.
            let distance = scratch[prev + n]
            return distance > maxDistance ? maxDistance + 1 : distance
        }
    }

    /// Banded Levenshtein: only the diagonal band `|i − j| ≤ maxDistance` is evaluated (cells outside
    /// it can only hold distances `> maxDistance`). O(`a.count`·`maxDistance`). Returns the exact
    /// distance when it is `≤ maxDistance`, else `maxDistance + 1`.
    public static func editDistanceBanded<Element: Equatable>(
        _ a: [Element], _ b: [Element], maxDistance k: Int
    ) -> Int {
        let m = a.count
        let n = b.count
        if abs(m - n) > k { return k + 1 }
        if m == 0 { return n <= k ? n : k + 1 }
        if n == 0 { return m <= k ? m : k + 1 }
        return a.withUnsafeBufferPointer { aBuf in
            b.withUnsafeBufferPointer { bBuf in
                bandedMatrix(a: aBuf, b: bBuf, maxDistance: k)
            }
        }
    }

    /// Core of ``editDistanceBanded(_:_:maxDistance:)`` over borrowed buffers. The two rolling rows
    /// share one `withUnsafeTemporaryAllocation` block reached through unchecked subscripts, so the
    /// banded loop carries no per-cell bounds check and allocates no rows. The whole block is
    /// initialized to `inf` up front: cells outside the band are never written in a given row, so a
    /// later read of one must see `inf` (unreachable) rather than uninitialized scratch memory.
    private static func bandedMatrix<Element: Equatable>(
        a: UnsafeBufferPointer<Element>, b: UnsafeBufferPointer<Element>, maxDistance k: Int
    ) -> Int {
        let m = a.count
        let n = b.count
        // `inf` is one past the bound: any path through it is already over budget.
        let inf = k + 1
        return withUnsafeTemporaryAllocation(of: Int.self, capacity: 2 * (n + 1)) { scratch in
            var prev = 0
            var cur = n + 1
            for idx in 0 ..< (2 * (n + 1)) { scratch[idx] = inf }
            for j in 0 ... Swift.min(k, n) { scratch[j] = j }  // prev region seed (prev == 0)
            for i in 1 ... m {
                let lo = Swift.max(0, i - k)
                let hi = Swift.min(n, i + k)
                if lo > 0 { scratch[cur + lo - 1] = inf }  // left boundary read by current[j-1] at j == lo
                var rowMin = inf
                for j in lo ... hi {
                    let value: Int
                    if j == 0 {
                        value = i  // reached only while i ≤ k (lo == 0)
                    } else {
                        let cost = a[i - 1] == b[j - 1] ? 0 : 1
                        let deletion = scratch[prev + j] + 1
                        let insertion = scratch[cur + j - 1] + 1
                        let substitution = scratch[prev + j - 1] + cost
                        value = Swift.min(deletion, insertion, substitution)
                    }
                    scratch[cur + j] = value
                    if value < rowMin { rowMin = value }
                }
                if hi < n { scratch[cur + hi + 1] = inf }  // right boundary read by previous[j] next row
                if rowMin > k { return k + 1 }
                swap(&prev, &cur)
            }
            let distance = scratch[prev + n]
            return distance > k ? k + 1 : distance
        }
    }
}

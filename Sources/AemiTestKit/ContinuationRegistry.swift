import HeapModule

/// Internal infrastructure shared by `TestClock` (key = wake deadline) and `AsyncEventProbe`
/// (key = event threshold): a set of suspended continuations, each parked under a `Key`
/// and woken in `Key` order once a boundary advances past it. This de-dupes the
/// park / wake / cancel choreography that was hand-rolled, near-identically, in each.
///
/// A `Heap` keeps the parked keys ordered, so a wake pops only the entries that are due
/// (O(log n) per pop) instead of scanning and sorting every parked continuation. A side
/// table maps id → (key, continuation) as the source of truth for liveness, giving O(1)
/// cancellation; a cancelled entry's heap slot is left in place and skipped when later
/// reached (lazy deletion), so cancellation never scans the heap. A slot whose key is never
/// reached (a far-off timeout that was cancelled once its event arrived) would stay forever,
/// so the heap is rebuilt from the live entries once stale slots outnumber live ones: the
/// rebuild is O(n) after at least n cancellations, O(1) amortized.
///
/// The type is iterative throughout — no recursion. It is *not* `Sendable` (it is mutable state)
/// and is meant to live inside a `Mutex`-guarded state, exactly as the originals did. Resume
/// continuations **outside** the lock. The continuations are *checked*: resuming one twice traps with a
/// message, and dropping one without resuming it logs a leak instead of hanging in silence.
struct ContinuationRegistry<Key: Comparable, Value> {
    /// A parked key plus the id that ties it back to the liveness table. Ordered by key,
    /// then id, so equal keys wake in a stable, deterministic order.
    private struct Entry: Comparable {
        let key: Key
        let id: UInt64
        static func < (lhs: Entry, rhs: Entry) -> Bool {
            lhs.key == rhs.key ? lhs.id < rhs.id : lhs.key < rhs.key
        }
    }

    private var ordered = Heap<Entry>()
    private var live: [UInt64: Parked] = [:]
    private var nextID: UInt64 = 0
    /// How many live entries were parked with `counted: false`.
    private var uncounted = 0

    private struct Parked {
        let key: Key
        let continuation: CheckedContinuation<Value, any Error>
        let counted: Bool
    }

    /// The number of *live* parked continuations that count (cancelled / woken ones, and ones parked with
    /// `counted: false`, excluded).
    var count: Int { live.count - uncounted }

    /// The number of live continuations parked with `counted: false`.
    var uncountedCount: Int { uncounted }

    /// Heap slots held, live or stale. Exposed for tests that pin the compaction bound.
    var storedSlotCount: Int { ordered.count }

    /// Stale slots are rebuilt away once they outnumber the live entries, but never below this floor,
    /// so a registry that churns a handful of entries does not rebuild on every cancel.
    private static var compactionFloor: Int { 32 }

    /// The furthest counted key still live, or `nil` if none — the "drain to the end"
    /// boundary `TestClock.runToLastSleeper()` advances to.
    var maxKey: Key? { live.values.lazy.filter(\.counted).map(\.key).max() }

    /// Vend a fresh identifier so the caller can build its cancellation handler before it
    /// decides whether to actually park.
    mutating func makeID() -> UInt64 {
        defer { nextID &+= 1 }
        return nextID
    }

    /// Park `continuation` under `key`, keyed by a previously-vended `id`.
    ///
    /// A continuation parked with `counted: false` is woken like any other but is left out of ``count``
    /// and ``maxKey``: it belongs to the test harness, not to the code under test.
    mutating func park(
        id: UInt64, key: Key, _ continuation: CheckedContinuation<Value, any Error>, counted: Bool = true
    ) {
        live[id] = Parked(key: key, continuation: continuation, counted: counted)
        if !counted { uncounted += 1 }
        ordered.insert(Entry(key: key, id: id))
    }

    /// Remove the live entry parked under `id`, keeping the uncounted tally in step.
    private mutating func take(_ id: UInt64) -> CheckedContinuation<Value, any Error>? {
        guard let parked = live.removeValue(forKey: id) else { return nil }
        if !parked.counted { uncounted -= 1 }
        return parked.continuation
    }

    /// Remove and return every live continuation whose key is `<= bound`, in ascending
    /// key order, each paired with `value`. Stale (cancelled) slots are dropped silently.
    mutating func wake(upTo bound: Key, with value: Value) -> [(
        CheckedContinuation<Value, any Error>, Value
    )] {
        var woken: [(CheckedContinuation<Value, any Error>, Value)] = []
        while let next = ordered.min, next.key <= bound {
            _ = ordered.popMin()
            if let continuation = take(next.id) {
                woken.append((continuation, value))
            }
        }
        return woken
    }

    /// Remove and return the single longest-waiting live continuation (lowest key, then
    /// lowest id), skipping stale slots — a one-permit release for gate / semaphore use.
    mutating func wakeOne() -> CheckedContinuation<Value, any Error>? {
        while let next = ordered.min {
            _ = ordered.popMin()
            if let continuation = take(next.id) {
                return continuation
            }
        }
        return nil
    }

    /// Remove and return every live continuation, in ascending key order (then park order), emptying the
    /// registry. For releasing everything at the end of a test.
    mutating func drain() -> [CheckedContinuation<Value, any Error>] {
        let ids = live.map { Entry(key: $0.value.key, id: $0.key) }.sorted()
        let continuations = ids.compactMap { take($0.id) }
        ordered = Heap()
        return continuations
    }

    /// The keys of the live entries, ascending (then park order), each marked with whether it counts.
    /// For diagnostics.
    var parkedKeys: [(key: Key, counted: Bool)] {
        live.map { (Entry(key: $0.value.key, id: $0.key), $0.value.counted) }
            .sorted { $0.0 < $1.0 }
            .map { ($0.0.key, $0.1) }
    }

    /// Remove and return the continuation parked under `id` (for cancellation), if still
    /// live. Its heap slot is left for `wake` to skip, or for the next compaction to drop.
    mutating func remove(id: UInt64) -> CheckedContinuation<Value, any Error>? {
        let removed = take(id)
        if removed != nil { compactIfStale() }
        return removed
    }

    /// Rebuild the heap from the live entries when stale slots dominate.
    private mutating func compactIfStale() {
        let stale = ordered.count - live.count
        guard stale > Self.compactionFloor, stale > live.count else { return }
        ordered = Heap(live.map { Entry(key: $0.value.key, id: $0.key) })
    }
}

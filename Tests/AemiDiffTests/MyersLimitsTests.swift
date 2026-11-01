import AemiTestKit
import Testing

@testable import AemiDiff

/// The limits on Myers: the discard pass, the cost limit's split, cancellation, and the intraline budget.
struct MyersLimitsTests {
    /// Random pairs over a shared alphabet plus lines only one side has, so the discard pass always has work.
    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    private static func randomPairs(count: Int, maximumLength: Int, seed: UInt64) -> [(old: [Int], new: [Int])] {
        var random = SeededRNG(seed: seed)
        return (0 ..< count)
            .map { _ in
                let alphabet = 1 + random.uniform(8)
                func side(unique: Int) -> [Int] {
                    (0 ..< random.uniform(maximumLength + 1))
                        .map { _ in
                            random.uniform(4) == 0 ? unique + random.uniform(1_000) : random.uniform(alphabet)
                        }
                }
                return (side(unique: 1_000), side(unique: 2_000))
            }
    }

    /// Checks that `edits` walks both sides in order and turns `old` into `new`.
    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    private static func expectReconstructs(_ edits: [DiffEdit], old: [Int], new: [Int]) {
        var rebuilt: [Int] = []
        var oldCursor = 0
        var newCursor = 0
        var inOrder = true
        for edit in edits {
            switch edit {
                case .equal(let oldIndex, let newIndex):
                    inOrder =
                        inOrder && oldIndex == oldCursor && newIndex == newCursor && old[oldIndex] == new[newIndex]
                    rebuilt.append(new[newIndex])
                    oldCursor += 1
                    newCursor += 1
                case .delete(let oldIndex):
                    inOrder = inOrder && oldIndex == oldCursor
                    oldCursor += 1
                case .insert(let newIndex):
                    inOrder = inOrder && newIndex == newCursor
                    rebuilt.append(new[newIndex])
                    newCursor += 1
            }
        }
        #expect(inOrder)
        #expect(oldCursor == old.count && newCursor == new.count)
        #expect(rebuilt == new)
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    private static func cost(_ edits: [DiffEdit]) -> Int {
        edits.count { if case .equal = $0 { false } else { true } }
    }

    /// The length of the longest common subsequence, by dynamic programming: the oracle for the shortest script.
    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    private static func longestCommonSubsequence(_ old: [Int], _ new: [Int]) -> Int {
        var previous = [Int](repeating: 0, count: new.count + 1)
        for oldElement in old {
            var current = [Int](repeating: 0, count: new.count + 1)
            for (index, newElement) in new.enumerated() {
                current[index + 1] =
                    oldElement == newElement ? previous[index] + 1 : max(previous[index + 1], current[index])
            }
            previous = current
        }
        return previous[new.count]
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test(arguments: [false, true])
    func `applying the script to random old lines gives the new ones`(anchoringRareLines: Bool) {
        for (old, new) in Self.randomPairs(count: 400, maximumLength: 60, seed: 0x5EED_0001) {
            Self.expectReconstructs(LineDiff.diff(old, new, anchoringRareLines: anchoringRareLines), old: old, new: new)
        }
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `setting aside lines found on one side only keeps the script as short as it was`() {
        for (old, new) in Self.randomPairs(count: 300, maximumLength: 50, seed: 0x5EED_0002) {
            let shortest = old.count + new.count - 2 * Self.longestCommonSubsequence(old, new)
            #expect(Self.cost(LineDiff.diff(old, new, anchoringRareLines: false)) == shortest)
        }
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test(arguments: [1, 2, 3, 8])
    func `a search that reaches its cost limit still ends with a valid script`(costLimit: Int) {
        // A split that made no progress would hand the same problem back forever, and the time limit would end it.
        for (old, new) in Self.randomPairs(count: 300, maximumLength: 60, seed: 0x5EED_0003) {
            let edits = LineDiff.diff(old, new, anchoringRareLines: false, costLimit: costLimit)
            Self.expectReconstructs(edits, old: old, new: new)
        }
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `the cost limit's split is never a corner of the problem`() {
        var random = SeededRNG(seed: 0x5EED_0004)
        for _ in 0 ..< 2_000 {
            let n = 1 + random.uniform(12)
            let m = 1 + random.uniform(12)
            let round = 1 + random.uniform(n + m)
            // Reaches as the forward paths leave them, including past the box and none at all.
            let reaches = (0 ..< 2 * round + 1).map { _ in random.uniform(n + m + 3) }
            let split = LineDiff.costLimitedSplit(round: round, n: n, m: m) { reaches[$0 + round] }
            #expect((0 ... n).contains(split.x) && (0 ... m).contains(split.y))
            #expect(split.x + split.y > 0 && split.x + split.y < n + m)
        }
        for (n, m) in [(1, 1), (1, 5), (5, 1), (2, 2)] {
            let nowhere = LineDiff.costLimitedSplit(round: 3, n: n, m: m) { _ in 0 }
            let everywhere = LineDiff.costLimitedSplit(round: 3, n: n, m: m) { $0 + m }
            for split in [nowhere, everywhere] {
                #expect(split.x + split.y > 0 && split.x + split.y < n + m)
            }
        }
    }

    /// Runs `body` in a task that is cancelled before it starts.
    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    private static func cancelled<T: Sendable>(
        _ body: @escaping @Sendable () -> T
    ) async -> (value: T, sawCancellation: Bool)? {
        await withTaskGroup(of: (value: T, sawCancellation: Bool).self) { group in
            group.cancelAll()
            group.addTask { (body(), Task.isCancelled) }
            return await group.next()
        }
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `a cancelled diff stops within 64 rounds and still returns a valid script`() async throws {
        // The middle of a sequence against its reverse lies about 200 rounds in, so only a stopped search leaves
        // every line deleted and inserted.
        let old = Array(0 ..< 400)
        let new = Array(old.reversed())
        let result = try #require(await Self.cancelled { LineDiff.diff(old, new, anchoringRareLines: false) })
        #expect(result.sawCancellation)
        Self.expectReconstructs(result.value, old: old, new: new)
        #expect(Self.cost(result.value) == old.count + new.count)
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `round 0 never counts as cancelled, so a small change in a cancelled task keeps its shortest script`()
        async throws
    {
        let old = [1, 2, 3, 4, 5, 6, 7, 8]
        let new = [9, 2, 3, 4, 10, 6, 7, 11]
        let result = try #require(await Self.cancelled { LineDiff.diff(old, new, anchoringRareLines: false) })
        #expect(result.sawCancellation)
        #expect(Self.cost(result.value) == 6)
        #expect(result.value == LineDiff.diff(old, new, anchoringRareLines: false))
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `a histogram diff cancelled in its Myers fallback still returns a valid script`() async throws {
        let old = Array(0 ..< 400).map { $0 % 100 }
        let new = Array(old.reversed())
        let result = try #require(await Self.cancelled { LineDiff.diff(old, new, anchoringRareLines: true) })
        Self.expectReconstructs(result.value, old: old, new: new)
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `a bounded diff gives up exactly when the shortest script is longer than its budget`() {
        for (old, new) in Self.randomPairs(count: 300, maximumLength: 40, seed: 0x5EED_0005) {
            let shortest = Self.cost(LineDiff.diff(old, new, anchoringRareLines: false))
            #expect(LineDiff.diff(old, new, maximumEdits: shortest - 1) == nil || shortest == 0)
            let bounded = LineDiff.diff(old, new, maximumEdits: shortest)
            #expect(bounded.map(Self.cost) == shortest)
        }
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test
    func `intraline pairs changed past the limit return nil`() {
        let old = String(repeating: "a", count: 1_000)
        let new = String(repeating: "b", count: 1_000)
        #expect(IntralineDiff.emphasis(old: Substring(old), new: Substring(new)) == nil)
        #expect(IntralineDiff.emphasis(old: "let value = 1", new: "print(\"hello\")", granularity: .word) == nil)
        let within = IntralineDiff.emphasis(old: "let value = 1", new: "let value = 12")
        #expect(within?.new == [13 ..< 14])
    }
}

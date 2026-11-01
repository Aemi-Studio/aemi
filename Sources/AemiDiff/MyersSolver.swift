/// Linear-space Myers ("An O(ND) Difference Algorithm and Its Variations", section 4b) with git's cost limit: a
/// middle-snake search that passes `costLimit` rounds splits its problem heuristically instead of finding the middle.
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
struct MyersSolver<Element: Equatable> {
    private enum Work {
        case solve(old: Range<Int>, new: Range<Int>)
        case equal(old: Int, new: Int, count: Int)
    }

    private struct Snake {
        let x: Int
        let y: Int
        let u: Int
        let v: Int
        let edits: Int
    }

    /// How a middle-snake search ended.
    private enum Search {
        case found(Snake)
        /// The task was cancelled: the search stopped without a split, which in round 0 would make no progress.
        case cancelled
        /// The script is longer than `maximumEdits`.
        case overBudget
    }

    private let old: [Element]
    private let new: [Element]
    private var forward: [Int]
    private var backward: [Int]
    private let offset: Int
    private let costLimit: Int
    private let maximumEdits: Int
    /// Set once a cancellation stopped a search: every problem left is then deleted and inserted whole, a valid
    /// script if not the shortest.
    private(set) var wasCancelled = false
    /// Set when the script proved longer than `maximumEdits`; the edits appended so far are then incomplete.
    private(set) var exceededBudget = false
    /// Set once a search reached the cost limit and split its problem heuristically: the script may not be the
    /// shortest.
    private(set) var reachedCostLimit = false

    init(old: [Element], new: [Element], costLimit: Int, maximumEdits: Int = .max) {
        self.old = old
        self.new = new
        let maximum = (old.count + new.count + 1) / 2 + 1
        offset = maximum + 1
        forward = Array(repeating: 0, count: 2 * maximum + 3)
        backward = forward
        self.costLimit = costLimit
        self.maximumEdits = maximumEdits
    }

    mutating func solve(old oldRange: Range<Int>, new newRange: Range<Int>, into edits: inout [DiffEdit]) {
        var stack: [Work] = [.solve(old: oldRange, new: newRange)]

        while let work = stack.popLast() {
            switch work {
                case .equal(let oldStart, let newStart, let count):
                    for index in 0 ..< count {
                        edits.append(.equal(old: oldStart + index, new: newStart + index))
                    }

                case .solve(let oldRange, let newRange):
                    if oldRange.isEmpty || newRange.isEmpty || wasCancelled {
                        for index in oldRange { edits.append(.delete(old: index)) }
                        for index in newRange { edits.append(.insert(new: index)) }
                        continue
                    }

                    let snake: Snake
                    switch middleSnake(old: oldRange, new: newRange) {
                        case .found(let found): snake = found
                        case .cancelled:
                            wasCancelled = true
                            stack.append(.solve(old: oldRange, new: newRange))
                            continue
                        case .overBudget:
                            exceededBudget = true
                            return
                    }
                    if snake.edits > maximumEdits {
                        exceededBudget = true
                        return
                    }
                    if snake.edits > 1 {
                        stack.append(
                            .solve(
                                old: (oldRange.lowerBound + snake.u) ..< oldRange.upperBound,
                                new: (newRange.lowerBound + snake.v) ..< newRange.upperBound
                            )
                        )
                        stack.append(
                            .equal(
                                old: oldRange.lowerBound + snake.x,
                                new: newRange.lowerBound + snake.y,
                                count: snake.u - snake.x
                            )
                        )
                        stack.append(
                            .solve(
                                old: oldRange.lowerBound ..< (oldRange.lowerBound + snake.x),
                                new: newRange.lowerBound ..< (newRange.lowerBound + snake.y)
                            )
                        )
                    } else {
                        appendTrivial(old: oldRange, new: newRange, into: &edits)
                    }
            }
        }
    }

    /// Handles an edit script of size at most one: the shorter side is entirely contained in the longer one.
    private func appendTrivial(old oldRange: Range<Int>, new newRange: Range<Int>, into edits: inout [DiffEdit]) {
        let n = oldRange.count
        let m = newRange.count
        let common = min(n, m)
        var index = 0
        while index < common, old[oldRange.lowerBound + index] == new[newRange.lowerBound + index] {
            edits.append(.equal(old: oldRange.lowerBound + index, new: newRange.lowerBound + index))
            index += 1
        }
        if m > n {
            edits.append(.insert(new: newRange.lowerBound + index))
        } else if n > m {
            edits.append(.delete(old: oldRange.lowerBound + index))
        }
        let oldRest = oldRange.lowerBound + index + (n > m ? 1 : 0)
        let newRest = newRange.lowerBound + index + (m > n ? 1 : 0)
        for rest in 0 ..< (common - index) {
            edits.append(.equal(old: oldRest + rest, new: newRest + rest))
        }
    }

    private mutating func middleSnake(old oldRange: Range<Int>, new newRange: Range<Int>) -> Search {
        let n = oldRange.count
        let m = newRange.count
        let delta = n - m
        let isOdd = delta & 1 != 0
        let maximum = (n + m + 1) / 2 + 1

        forward[offset + 1] = 0
        backward[offset + 1] = 0

        for d in 0 ... maximum {
            // Read from synchronous code running in a task; never in round 0, where every search would stop.
            if d > 0, d & 63 == 0, Task.isCancelled { return .cancelled }
            // No round before this one met the other search, so the script holds at least 2d - 1 edits.
            if 2 * d - 1 > maximumEdits { return .overBudget }
            if d >= costLimit {
                reachedCostLimit = true
                let split = LineDiff.costLimitedSplit(round: d, n: n, m: m) { forward[offset + $0] }
                return .found(Snake(x: split.x, y: split.y, u: split.x, v: split.y, edits: 2 * d))
            }

            var k = -d
            while k <= d {
                var x =
                    if k == -d || (k != d && forward[offset + k - 1] < forward[offset + k + 1]) {
                        forward[offset + k + 1]
                    } else {
                        forward[offset + k - 1] + 1
                    }
                var y = x - k
                let startX = x
                let startY = y
                while x < n, y < m, old[oldRange.lowerBound + x] == new[newRange.lowerBound + y] {
                    x += 1
                    y += 1
                }
                forward[offset + k] = x

                if isOdd {
                    let backwardK = delta - k
                    if backwardK >= -(d - 1), backwardK <= d - 1, x + backward[offset + backwardK] >= n {
                        return .found(Snake(x: startX, y: startY, u: x, v: y, edits: 2 * d - 1))
                    }
                }
                k += 2
            }

            k = -d
            while k <= d {
                var x =
                    if k == -d || (k != d && backward[offset + k - 1] < backward[offset + k + 1]) {
                        backward[offset + k + 1]
                    } else {
                        backward[offset + k - 1] + 1
                    }
                var y = x - k
                let startX = x
                let startY = y
                while x < n, y < m, old[oldRange.upperBound - 1 - x] == new[newRange.upperBound - 1 - y] {
                    x += 1
                    y += 1
                }
                backward[offset + k] = x

                if !isOdd {
                    let forwardK = delta - k
                    if forwardK >= -d, forwardK <= d, x + forward[offset + forwardK] >= n {
                        return .found(Snake(x: n - x, y: m - y, u: n - startX, v: m - startY, edits: 2 * d))
                    }
                }
                k += 2
            }
        }

        preconditionFailure("Myers middle snake search must terminate within (N + M + 1) / 2 + 1 iterations")
    }
}

/// How the searches of one line diff ended: whether a cancellation stopped one, and whether one settled at the cost
/// limit, either of which leaves a valid script that may not be the shortest.
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
struct SearchOutcome: Equatable {
    var wasCancelled = false
    var reachedCostLimit = false

    mutating func merge(_ other: SearchOutcome) {
        wasCancelled = wasCancelled || other.wasCancelled
        reachedCostLimit = reachedCostLimit || other.reachedCostLimit
    }
}

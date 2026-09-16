/// Transforms `items` concurrently with at most `limit` transforms in flight, preserving the input
/// order in the result.
///
/// The transforms run as child tasks of one throwing task group: the first error thrown by any
/// transform is rethrown, and the transforms still running are cancelled. Cancelling the caller
/// cancels every transform in flight.
///
/// - Parameters:
///   - items: The inputs, transformed in order of submission.
///   - limit: The maximum number of transforms in flight; a value below one behaves as one.
///   - transform: The transform applied to each item; it runs on the cooperative pool.
/// - Returns: One result per item, at the item's index.
/// - Throws: The first error a transform throws, or `CancellationError` if the caller is cancelled.
/// - Complexity: O(n) tasks over the whole run, O(`limit`) in flight, O(n) result storage.
public func mapConcurrently<Item: Sendable, Result: Sendable>(
    _ items: [Item],
    limit: Int,
    _ transform: @Sendable @escaping (Item) async throws -> Result
) async throws -> [Result] {
    let limit = max(limit, 1)
    var results = [Result?](repeating: nil, count: items.count)
    try await withThrowingTaskGroup(of: (Int, Result).self) { group in
        var next = 0
        func enqueue() {
            let index = next
            let item = items[index]
            group.addTask { (index, try await transform(item)) }
            next += 1
        }
        while next < min(limit, items.count) {
            enqueue()
        }
        while let (index, result) = try await group.next() {
            results[index] = result
            if next < items.count {
                enqueue()
            }
        }
    }
    return results.compactMap { $0 }
}

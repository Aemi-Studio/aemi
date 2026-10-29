internal import Synchronization

/// Paths a watcher's owner wrote itself, each suppressed for `window` after it was recorded. A `Mutex` guards it, so
/// event handlers running outside any task consult it without an `await`. It takes explicit times, so its tests need
/// no clock.
final class SuppressionWindow: Sendable {
    private let timestamps = Mutex<[String: Duration]>([:])
    private let window: Duration

    init(window: Duration) {
        self.window = window
    }

    func record(_ path: String, now: Duration) {
        timestamps.withLock { table in
            table[path] = now
            // Every insertion also evicts the entries whose window has passed: a path whose event never came would
            // otherwise stay forever, and a long session of writes would grow the table without bound.
            if table.count > 1 {
                table = table.filter { now - $0.value < window }
            }
        }
    }

    func isSuppressed(_ path: String, now: Duration) -> Bool {
        timestamps.withLock { table in
            guard let recordedAt = table[path] else { return false }
            if now - recordedAt < window { return true }
            table.removeValue(forKey: path)
            return false
        }
    }
}

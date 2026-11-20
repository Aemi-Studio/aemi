#if canImport(ObjectiveC)
    import Foundation

    /// A key-value observable value for the `KeyValueProbe` tests.
    final class KeyValueObserved: NSObject, @unchecked Sendable {
        @objc dynamic var number = 0
    }
#endif

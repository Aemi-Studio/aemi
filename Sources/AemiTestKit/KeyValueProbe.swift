#if canImport(ObjectiveC)
    public import Foundation
    // `public import`: the probe's creation site is Swift Testing's `SourceLocation`.
    public import Testing

    /// A key path's values as ``AsyncEventProbe`` events: the value it holds when the probe is made, then each new one,
    /// recorded as key-value observing announces it, on whatever thread makes the change.
    ///
    /// For state that Foundation, AppKit or WebKit publish by key-value observing (an operation's `isFinished`, a web
    /// view's `isLoading` or `estimatedProgress`, a player's `status`): waited for without polling, and without missing a
    /// value that came and went. The observation lasts as long as the probe.
    ///
    /// ```swift
    /// let loading = KeyValueProbe(webView, \.isLoading)
    /// webView.load(request)
    /// try await loading.wait(history: { $0.contains(true) && $0.last == false })
    /// ```
    ///
    /// Needs the Objective-C runtime.
    public final class KeyValueProbe<Root: NSObject, Value: Sendable>: Sendable {
        /// Every value seen, oldest first: the probe's `events`.
        public let values: AsyncEventProbe<Value>
        private let observation: NSKeyValueObservation

        /// Observes `keyPath` of `object` from now on, starting with its current value.
        ///
        /// - Parameters:
        ///   - object: The observed object; the probe does not keep it alive.
        ///   - keyPath: A key-value observable property (`@objc dynamic`, or KVO-compliant).
        ///   - label: Names the probe in a timeout message; the type and key path if empty.
        ///   - sourceLocation: Where the probe is made, reported by a timeout message.
        public init(
            _ object: Root,
            _ keyPath: KeyPath<Root, Value>,
            label: String = "",
            sourceLocation: SourceLocation = #_sourceLocation
        ) {
            let values = AsyncEventProbe<Value>(
                label: label.isEmpty ? "\(Root.self) \(keyPath)" : label,
                sourceLocation: sourceLocation
            )
            self.values = values
            // On Swift 6.3, `KeyPath` is not yet `Sendable` even though Foundation's KVO observer
            // closure is `@Sendable`. Read `change.newValue` (which is already `Value?`, `Sendable`)
            // so the closure captures only `values` and never captures `keyPath`.
            observation = object.observe(keyPath, options: [.initial, .new]) { _, change in
                if let value = change.newValue {
                    values.record(value)
                }
            }
        }

        deinit {
            observation.invalidate()
        }

        /// Suspends until the latest value satisfies `condition`; that value.
        ///
        /// - Throws: ``AsyncEventProbeTimeoutError`` if no value satisfies it within `timeout` on `clock`, or
        ///   `CancellationError` if the awaiting task is cancelled.
        @discardableResult
        public func wait<C: Clock>(
            until condition: @escaping @Sendable (Value) -> Bool,
            within timeout: C.Duration,
            clock: C
        ) async throws -> Value {
            let seen = try await values.wait(until: { $0.last.map(condition) ?? false }, within: timeout, clock: clock)
            guard let last = seen.last else { preconditionFailure("a satisfied wait has seen a value") }
            return last
        }

        /// ``wait(until:within:clock:)`` over real time. The timeout is a hang guard, so it is generous by default.
        @discardableResult
        public func wait(
            until condition: @escaping @Sendable (Value) -> Bool,
            timeout: Duration = .seconds(30)
        ) async throws -> Value {
            try await wait(until: condition, within: timeout, clock: ContinuousClock())
        }

        /// Suspends until the values seen so far, oldest first, satisfy `condition` — a change from one value to
        /// another, such as loading and then not; all of them.
        ///
        /// - Throws: ``AsyncEventProbeTimeoutError`` if they do not within `timeout`, or `CancellationError`.
        @discardableResult
        public func wait(
            history condition: @escaping @Sendable ([Value]) -> Bool,
            timeout: Duration = .seconds(30)
        ) async throws -> [Value] {
            try await values.wait(until: condition, within: timeout, clock: ContinuousClock())
        }
    }
#endif

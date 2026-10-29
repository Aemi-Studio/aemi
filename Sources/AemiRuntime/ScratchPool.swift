public import Synchronization

/// A pool of reusable scratch values that grows to the number of concurrent users and no further: taking and returning one is a
/// short lock, and nothing is held while the value is used. For per-call working memory too large to allocate on each call (an
/// automaton's thread lists, say). Promoted from AemiRegex (aemi ADR 0018). Unlike `ResourcePool`, it makes values on demand and never
/// runs dry.
///
/// Inlinable, so a caller's module specializes it for its own `Value`: unspecialized, every call looked up the generic metadata of
/// the pool's internals at run time, which cost AemiRegex about 0.45 µs a search (profiled, aemi ADR 0018).
public final class ScratchPool<Value>: Sendable {
    @usableFromInline let free = Mutex<[Box]>([])
    @usableFromInline let make: @Sendable () -> Value

    /// - Parameter make: makes a value when none is free.
    @inlinable
    public init(make: @escaping @Sendable () -> Value) { self.make = make }

    /// Runs `body` with exclusive use of a scratch value, then returns it to the pool.
    @inlinable
    public func withScratch<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        let box = free.withLock { $0.popLast() } ?? Box(make())
        defer { free.withLock { $0.append(box) } }
        return try body(&box.value)
    }

    /// A value in a reference, so the pool moves a pointer instead of copying the value.
    ///
    /// `@unchecked Sendable` and the unchecked exclusivity of `value` are sound under one rule: a box is in the pool or in exactly one
    /// `withScratch`, never both. The pool hands it out under its lock and takes it back under its lock, so no two accesses to `value`
    /// can overlap, and the run-time check (a `swift_beginAccess` per search, in profiles) proves nothing the lock does not.
    @usableFromInline
    final class Box: @unchecked Sendable {
        @exclusivity(unchecked) @usableFromInline var value: Value
        @usableFromInline init(_ value: Value) { self.value = value }
    }
}

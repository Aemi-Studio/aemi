//
//  Tracer.swift
//  HTTPConcurrencyTests
//
//  A reference type that counts its own deallocation. It is the leak probe behind the ``BoundedLRU``
//  lifetime suite: the recency list it replaces threaded `class` nodes with strong `prev` *and* `next`
//  pointers — a reference cycle no unlink can break, so every evicted entry stayed resident for the
//  life of the process (CWE-401). Counting deallocations is the only way to assert that cannot return.
//

import Synchronization

/// A class whose deallocations are counted process-wide, for asserting that a container releases it.
final class Tracer: Sendable {
    private static let deallocations = Atomic<Int>(0)

    /// An identifying label, so a test can assert *which* instance a container still holds.
    let label: Int

    /// Creates a tracer identified by `label`.
    init(_ label: Int) {
        self.label = label
    }

    deinit {
        Self.deallocations.wrappingAdd(1, ordering: .relaxed)
    }

    /// How many tracers have deallocated since the last ``resetDeallocationCount()``.
    static var deallocationCount: Int {
        deallocations.load(ordering: .relaxed)
    }

    /// Zeroes the count; call at the start of every (serialized) lifetime test.
    static func resetDeallocationCount() {
        deallocations.store(0, ordering: .relaxed)
    }
}

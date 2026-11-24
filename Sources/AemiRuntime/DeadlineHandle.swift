//
//  DeadlineHandle.swift
//  AemiRuntime
//
//  The generation-tokened identity of one timer in a ``DeadlineWheel``.
//
//  A wheel recycles slots, so "slot 7" alone is not an identity: a connection torn down while its
//  entry was still in flight could otherwise have its lapse charged against whatever connection next
//  landed on slot 7 — a use-after-free in timer form (CWE-416 shape, reached without unsafe memory).
//  Releasing a slot bumps its generation, so a stale handle can never again match the live occupant
//  and every operation carrying it degrades to a no-op.
//

/// The identity of one registered timer: a recycled slot plus the generation that owns it.
///
/// Two words, trivially copyable, and never allocated — arming is a hot-path operation that happens
/// around every read, so the identity it carries must cost nothing to pass.
public struct DeadlineHandle: Sendable, Equatable {
    /// The wheel slot this timer occupies.
    public let slot: Int32

    /// Which occupancy of ``slot`` this handle refers to; bumped on release.
    public let generation: UInt32

    public init(slot: Int32, generation: UInt32) {
        self.slot = slot
        self.generation = generation
    }
}

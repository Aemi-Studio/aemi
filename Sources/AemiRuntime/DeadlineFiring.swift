//
//  DeadlineFiring.swift
//  AemiRuntime
//
//  The result of one ``DeadlineWheel`` firing turn.
//
//  The count exists so the watchdog only runs its (possibly `async`) follow-up work when something
//  actually lapsed: a watchdog wakes on every armed instant, including ones the serve loop disarmed
//  while it slept, and those turns must cost nothing.
//

/// What one ``DeadlineWheel/fireLapsed(at:)`` turn did.
public struct DeadlineFiring: Sendable, Equatable {
    /// Whether nothing lapsed — true on a turn whose target was disarmed while the watchdog slept, so
    /// the watchdog's follow-up work is skipped entirely.
    public let isEmpty: Bool

    /// Whether any lapsed timer asked the watchdog to stop.
    public let action: DeadlineLapseAction

    public init(isEmpty: Bool, action: DeadlineLapseAction) {
        self.isEmpty = isEmpty
        self.action = action
    }
}

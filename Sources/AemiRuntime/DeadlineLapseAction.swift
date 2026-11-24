//
//  DeadlineLapseAction.swift
//  AemiRuntime
//
//  What a lapsed timer asks its watchdog to do next.
//
//  The three deadline shapes this server arms escalate differently: an HTTP/1.1 connection-wide idle
//  lapse must end the serve loop (RFC 9112 §9.3), while an HTTP/2 send lapse or an HTTP/3 per-stream
//  lapse (RFC 9114 §4.1, §8.1) reports through a mailbox and leaves the watchdog running for the
//  connection's other timers. Making that the callback's return value is what let all three collapse
//  onto one watchdog.
//

/// What the watchdog does after a lapse callback returns.
public enum DeadlineLapseAction: Sendable, Equatable {
    /// Keep serving this wheel's other timers — the lapse was handled out of band.
    case keepWatching

    /// Return from the watchdog, which ends the task group racing it against the serve loop.
    case stopWatching
}

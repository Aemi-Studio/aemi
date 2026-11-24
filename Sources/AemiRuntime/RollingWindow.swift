//
//  RollingWindow.swift
//  HTTPConcurrency
//
//  The boundary half of a rate-limited budget, shared by the HTTP/2 (Rapid-Reset + control-frame) and
//  HTTP/3 (reset) abuse budgets. It tracks only the window's start; the caller keeps the per-window
//  counts and zeroes them when the window rolls over, so a cap is a *rate* over the interval rather than
//  a per-connection total (CVE-2023-44487). Measured against an injected ``MonotonicNowProvider`` so a
//  test pins time with zero real waiting.
//

/// A monotonic rolling time window for rate-limited budgets.
public struct RollingWindow: Sendable, Equatable {
    private var start: MonotonicNanoseconds
    private let intervalNanos: MonotonicNanoseconds

    /// Creates a window of `interval` nanoseconds starting at `start` (both monotonic nanoseconds).
    public init(start: MonotonicNanoseconds, interval: MonotonicNanoseconds) {
        self.start = start
        self.intervalNanos = interval
    }

    /// Whether `now` has crossed into a new window — and, if so, restarts the window at `now`.
    ///
    /// Returns `true` exactly when the caller should zero its per-window counters. Monotonic time never
    /// runs backwards, so the signed subtraction cannot wrap; a stalled clock simply never rolls over.
    public mutating func rolledOver(at now: MonotonicNanoseconds) -> Bool {
        guard now - start >= intervalNanos else {
            return false
        }
        start = now
        return true
    }
}

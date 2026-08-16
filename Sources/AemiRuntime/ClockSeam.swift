#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Whole seconds since the Unix epoch — the unit a datetime function (e.g. SQL
/// `datetime('now')`) resolves against, expressed as `Int64` so a test can pin it
/// without a real clock.
public typealias EpochSeconds = Int64

/// The injection point for "what time is it (epoch seconds)". A library datetime
/// function takes `now: EpochSecondsProvider = LiveClock.epochSeconds` and a test passes
/// a closure returning a fixed instant — the first deterministic `datetime('now')`.
public typealias EpochSecondsProvider = @Sendable () -> EpochSeconds

/// Monotonic nanoseconds for elapsed-time / timeout logic (durability commit
/// timeouts, server timing) — never the wall clock, so it cannot run backwards.
public typealias MonotonicNanosecondsProvider = @Sendable () -> Int64

/// The shipped live defaults the seams point at. Pure `clock_gettime`, the same
/// source the AD-family datetime code already reads, so defaulting to these changes
/// nothing in production; only a test overrides them.
public enum LiveClock {
    /// Wall-clock seconds since the Unix epoch (`CLOCK_REALTIME`).
    public static let epochSeconds: EpochSecondsProvider = {
        var ts = timespec()
        clock_gettime(CLOCK_REALTIME, &ts)
        return Int64(ts.tv_sec)
    }

    /// Monotonic nanoseconds (`CLOCK_MONOTONIC`) for elapsed-time measurement.
    public static let monotonicNanoseconds: MonotonicNanosecondsProvider = {
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return Int64(ts.tv_sec) &* 1_000_000_000 &+ Int64(ts.tv_nsec)
    }
}

// MARK: - Back-compatibility (deprecated, renamed)

@available(*, deprecated, renamed: "EpochSecondsProvider")
public typealias EpochNowProvider = EpochSecondsProvider

@available(*, deprecated, renamed: "MonotonicNanosecondsProvider")
public typealias MonotonicNanoProvider = MonotonicNanosecondsProvider

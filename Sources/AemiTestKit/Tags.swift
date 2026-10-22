// `public import`: this file extends Swift Testing's `Tag` with public static members.
public import Testing

/// The canonical test tags the AD-family shares, so a CI lane can select or exclude a
/// category uniformly across all six packages (e.g. run only `.fuzz` + `.parity` in
/// the sanitizer lane, or exclude `.soak` from the fast lane).
extension Tag {
    /// Seeded fuzz / crash-injection suites that prove "never trap / hang / OOM".
    @Tag public static var fuzz: Self
    /// Differential-oracle suites comparing against a reference model (SQLite mirror,
    /// JS oracle, tape-vs-SAX).
    @Tag public static var parity: Self
    /// Property-based suites asserting an invariant over seeded random inputs.
    @Tag public static var property: Self
    /// Long-running soak / endurance suites.
    @Tag public static var soak: Self
    /// Concurrency / async-coordination suites.
    @Tag public static var concurrency: Self
    /// Benchmarks: they measure and record instead of asserting, and run only when a results file is named
    /// (``benchmarkResultsPath``), so the default test run skips them. Put it next to `.benchmarksRequested`.
    @Tag public static var bench: Self
}

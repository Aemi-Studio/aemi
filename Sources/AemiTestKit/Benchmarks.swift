// `public import`: ``Trait/benchmarksRequested`` is a Swift Testing trait.
public import Testing

#if canImport(Darwin)
    internal import Darwin
#elseif canImport(Glibc)
    internal import Glibc
#elseif canImport(Musl)
    internal import Musl
#endif

/// Where benchmark results go: a file named by an environment variable, set by whatever tool runs the benchmarks.
///
/// The variable's name is a parameter of every function here, so a package picks its own
/// (`MYPKG_BENCH_OUTPUT`) and a tool that runs several packages' benchmarks can tell them apart.
/// ``defaultEnvironmentVariable`` is used when none is given.
public enum BenchmarkOutput {
    /// The environment variable the functions read when no other is named.
    public static let defaultEnvironmentVariable = "AEMI_BENCH_OUTPUT"

    /// The results file named by `environmentVariable`, or `nil` when it is unset or empty, which is an
    /// ordinary test run: no benchmark runs then.
    public static func path(environmentVariable: String = defaultEnvironmentVariable) -> String? {
        guard let value = getenv(environmentVariable) else { return nil }
        let path = String(cString: value)
        return path.isEmpty ? nil : path
    }
}

/// The file benchmarks append their results to: the value of ``BenchmarkOutput/defaultEnvironmentVariable``. `nil` in an
/// ordinary test run, and then no benchmark runs. Use ``BenchmarkOutput/path(environmentVariable:)`` to name another
/// variable.
public var benchmarkResultsPath: String? { BenchmarkOutput.path() }

extension Trait where Self == ConditionTrait {
    /// Runs a benchmark only when a results file is named by ``BenchmarkOutput/defaultEnvironmentVariable``: Swift
    /// Testing cannot exclude a tag from a run, so the default `swift test` skips benchmarks through this trait.
    public static var benchmarksRequested: Self {
        benchmarksRequested(environmentVariable: BenchmarkOutput.defaultEnvironmentVariable)
    }

    /// Runs a benchmark only when `environmentVariable` names a results file.
    public static func benchmarksRequested(environmentVariable: String) -> Self {
        .enabled(
            if: BenchmarkOutput.path(environmentVariable: environmentVariable) != nil,
            "benchmarks run only when \(environmentVariable) names a results file")
    }
}

/// One measured figure of a benchmark, as the tool that reads the results file sees it.
public struct BenchmarkResult: Sendable {
    /// Which way is better. A figure that moves the other way is a regression.
    public enum Direction: String, Sendable {
        case lower
        case higher
    }

    /// Dotted and stable: it is the key of the committed baseline.
    public var name: String
    public var unit: String
    public var direction: Direction
    public var value: Double
    /// The fraction the figure may move the wrong way before it counts as a regression, written into the baseline when
    /// the figure is first recorded. 0 for a deterministic count, a few percent for retired instructions.
    public var tolerance: Double
    /// Whether a regression fails the gate. A wall-clock time depends on what else the machine runs, so it is reported
    /// and never fails; a count of instructions or allocations is enforced.
    public var enforced: Bool

    public init(
        name: String, unit: String, direction: Direction, value: Double, tolerance: Double = 0, enforced: Bool = true
    ) {
        self.name = name
        self.unit = unit
        self.direction = direction
        self.value = value
        self.tolerance = tolerance
        self.enforced = enforced
    }
}

/// Appends a result to the file named by `environmentVariable`, one JSON object per line:
/// `{"name":..,"unit":..,"direction":..,"tolerance":..,"enforced":..,"value":..}`. Does nothing when no file is
/// named, so a benchmark can call it unconditionally.
public func recordBenchmark(
    _ result: BenchmarkResult, environmentVariable: String = BenchmarkOutput.defaultEnvironmentVariable
) {
    guard let path = BenchmarkOutput.path(environmentVariable: environmentVariable) else { return }
    for text in [result.name, result.unit] {
        precondition(!text.contains { $0 == "\"" || $0 == "\\" || $0.isNewline }, "'\(text)' needs JSON escaping")
    }
    let line =
        "{\"name\":\"\(result.name)\",\"unit\":\"\(result.unit)\",\"direction\":\"\(result.direction.rawValue)\","
        + "\"tolerance\":\(result.tolerance),\"enforced\":\(result.enforced),\"value\":\(result.value)}\n"
    // One `write` on an `O_APPEND` descriptor lands whole, so benchmarks running at once cannot interleave their lines.
    let descriptor = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    precondition(descriptor >= 0, "cannot open the benchmark results file \(path)")
    defer { close(descriptor) }
    let bytes = Array(line.utf8)
    let written = bytes.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
    precondition(written == bytes.count, "cannot write the benchmark results file \(path)")
}

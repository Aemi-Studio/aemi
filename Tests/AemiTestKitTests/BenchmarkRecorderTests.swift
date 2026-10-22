import Foundation
import Testing

@testable import AemiTestKit

struct BenchmarkRecorderTests {
    @Test
    func `a benchmark run is off unless a results file is named`() {
        // The test run itself names none.
        #expect(benchmarkResultsPath == nil)
        #expect(BenchmarkOutput.path(environmentVariable: "AEMI_TESTKIT_NO_SUCH_VARIABLE") == nil)
        recordBenchmark(BenchmarkResult(name: "ignored", unit: "x", direction: .lower, value: 1))  // no file, no effect
    }

    // Swift Testing's exit tests abort in the child process under a sanitizer runtime.
    @Test(.disabled(if: sanitizerRuntimeLoaded, "exit tests abort under a sanitizer"))
    func `results are appended to the named file as one JSON object per line`() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "bench-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        // A child process, because the environment is process-wide and other tests read it.
        await #expect(processExitsWith: .success) { [path = file.path as String] in
            setenv("AEMI_BENCH_OUTPUT", path, 1)
            recordBenchmark(
                BenchmarkResult(
                    name: "a.b", unit: "MiB/s", direction: .higher, value: 12.5, tolerance: 0.3, enforced: false))
            recordBenchmark(BenchmarkResult(name: "c", unit: "allocations", direction: .lower, value: 4))
        }
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(
            lines == [
                #"{"name":"a.b","unit":"MiB/s","direction":"higher","tolerance":0.3,"enforced":false,"value":12.5}"#,
                #"{"name":"c","unit":"allocations","direction":"lower","tolerance":0.0,"enforced":true,"value":4.0}"#
            ])
    }

    @Test(.disabled(if: sanitizerRuntimeLoaded, "exit tests abort under a sanitizer"))
    func `the environment variable is the caller's to name`() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "bench-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        await #expect(processExitsWith: .success) { [path = file.path as String] in
            setenv("MYPKG_BENCH_OUTPUT", path, 1)
            // The default variable is unset, so a result recorded against it goes nowhere.
            recordBenchmark(BenchmarkResult(name: "default", unit: "x", direction: .lower, value: 1))
            precondition(BenchmarkOutput.path() == nil)
            recordBenchmark(
                BenchmarkResult(name: "named", unit: "x", direction: .lower, value: 2),
                environmentVariable: "MYPKG_BENCH_OUTPUT")
            precondition(BenchmarkOutput.path(environmentVariable: "MYPKG_BENCH_OUTPUT") == path)
        }
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines.count == 1)
        #expect(lines.first?.contains(#""name":"named""#) == true)
    }

    @Test
    func `the benchmarks trait is disabled when its variable is unset`() async throws {
        let trait: ConditionTrait = .benchmarksRequested(environmentVariable: "AEMI_TESTKIT_NO_SUCH_VARIABLE")
        #expect(try await trait.evaluate() == false)
        #expect(try await ConditionTrait.benchmarksRequested.evaluate() == false)
    }
}

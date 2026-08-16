import Foundation
import PackagePlugin

/// Checks formatting and shipped-library discipline (`swift package lint`).
///
/// The single source of truth for the family's lint rules:
///   1. a formatting gate across the package via `swift format lint --strict` (consumer `.swift-format`);
///   2. shipped-library discipline over the declared shipped library targets:
///        - **no force unwrap / force try**, enforced by swift-format's *AST* rules (`NeverForceUnwrap`,
///          `NeverUseForceTry`) layered onto the consumer config. This catches every `x!` / `try!` — not a
///          fixed pattern set — and a reviewed exception opts out with `// swift-format-ignore: NeverForceUnwrap`.
///        - **no locale-sensitive `strtod`**, which is not a force-unwrap, so a small textual scan covers it;
///          a reviewed case opts out with a trailing `// lint:allow` comment.
///
/// Tests, plugins, macros, generators, and fuzz targets are exempt from rule 2 (they are not in the shipped
/// target list). Per-consumer specifics come from an optional `.adbuildtools.json` at the package root —
/// `{ "shippedTargets": ["Sources/Foo"], "strtodBan": true }`; when absent, `shippedTargets` defaults to
/// `["Sources"]` and the strtod ban is on.
@main
struct LintPlugin: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        let root = context.package.directoryURL
        let swift = try context.tool(named: "swift")
        let settings = LintSettings(root: root)
        var failed = false

        // 1. Formatting gate across the package (consumer `.swift-format`). Skip missing top-level paths
        //    (e.g. a package with no Tests/ or no Plugins/).
        let formatPaths = ["Sources", "Tests", "Plugins", "Package.swift"]
            .map { root.appending(path: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map(\.path)
        if !formatPaths.isEmpty,
            run(swift, ["format", "lint", "--strict", "--recursive"] + formatPaths) != 0
        {
            failed = true
        }

        // 1b. Size/complexity metrics gate — SwiftLint `--strict` over the synced `.swiftlint.yml`
        //     (file/type/function length, cyclomatic complexity, arity, nesting — the metrics
        //     swift-format cannot express). Mirrors the reusable `swift-quality.yml` CI step so local
        //     `swift package lint` and CI agree; enforcing, so any metric warning fails.
        if runSwiftLintMetrics(root: root) != 0 { failed = true }

        // 2a. Force-unwrap / force-try discipline — AST-based, scoped to the shipped library targets. The
        //     config is the consumer `.swift-format` with `NeverForceUnwrap` + `NeverUseForceTry` switched
        //     on, so the rule set never drifts from the checked-in config and there are no defaults-driven
        //     false positives.
        let shippedPaths = settings.shippedTargets
            .map { root.appending(path: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map(\.path)
        if settings.forceUnwrapBan, !shippedPaths.isEmpty {
            if let strict = strictConfig(root: root, work: context.pluginWorkDirectoryURL) {
                let args = ["format", "lint", "--strict", "--configuration", strict.path, "--recursive"]
                if run(swift, args + shippedPaths) != 0 { failed = true }
            } else {
                Diagnostics.error("could not derive the strict force-unwrap config from .swift-format")
                failed = true
            }
        }

        // 2b. Locale-sensitive `strtod` ban (not a force-unwrap, so swift-format can't express it).
        if settings.strtodBan, scanForbiddenStrtod(root: root, shippedTargets: settings.shippedTargets) {
            failed = true
        }

        // 3. Test-tree discipline (AD-family Phase 6): no inline PRNG re-rolls, untyped `#expect(throws:)`,
        //    or wall-clock assertions in the test tree. Each is gated by a `.adbuildtools.json` toggle and
        //    a per-line `// lint:allow` escape.
        if scanTestTreeDiscipline(root: root, settings: settings) { failed = true }

        // Throw (not merely diagnose) so the command exits non-zero and actually fails the hook / CI.
        if failed { throw LintError.failed }
        print("lint clean")
    }

    /// Run `swift <args>` synchronously; returns the exit status (non-zero ⇒ failure).
    private func run(_ swift: PluginContext.Tool, _ args: [String]) -> Int32 {
        let process = Process()
        process.executableURL = swift.url
        process.arguments = args
        do {
            try process.run()
        } catch {
            return 1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Runs the SwiftLint size/complexity metrics gate (`--strict`) over the package's synced
    /// `.swiftlint.yml`, matching the reusable `swift-quality.yml` CI step so local `swift package lint`
    /// and CI agree. SwiftLint is a system binary (Homebrew), not a toolchain tool, so it's resolved off
    /// `PATH` via `/usr/bin/env`; the plugin therefore execs an external tool and must be run with
    /// `--disable-sandbox`. A package without a `.swiftlint.yml` skips; a missing `swiftlint` binary is a
    /// hard failure (the gate must not silently pass).
    private func runSwiftLintMetrics(root: URL) -> Int32 {
        guard FileManager.default.fileExists(atPath: root.appending(path: ".swiftlint.yml").path) else {
            return 0
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["swiftlint", "lint", "--strict", "--config", ".swiftlint.yml"]
        process.currentDirectoryURL = root
        do {
            try process.run()
        } catch {
            Diagnostics.error("could not launch swiftlint — install it with `brew install swiftlint`")
            return 1
        }
        process.waitUntilExit()
        if process.terminationStatus == 127 {
            Diagnostics.error("swiftlint not found on PATH — install it with `brew install swiftlint`")
        }
        return process.terminationStatus
    }

    /// Derives a strict swift-format config in the plugin's work directory.
    ///
    /// The consumer `.swift-format` with the force-unwrap / force-try AST rules switched on. Returns nil if
    /// the base config can't be read, parsed, or rewritten — the caller treats that as a failure rather than
    /// silently skipping the check.
    private func strictConfig(root: URL, work: URL) -> URL? {
        let base = root.appending(path: ".swift-format")
        guard let data = try? Data(contentsOf: base),
            var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        var rules = (json["rules"] as? [String: Any]) ?? [:]
        rules["NeverForceUnwrap"] = true
        rules["NeverUseForceTry"] = true
        json["rules"] = rules
        guard let out = try? JSONSerialization.data(withJSONObject: json) else { return nil }
        let dest = work.appending(path: "strict.swift-format")
        guard (try? out.write(to: dest)) != nil else { return nil }
        return dest
    }

    /// Scans the shipped library targets for the locale-sensitive `strtod(` C call.
    ///
    /// Returns true if any un-annotated use is found (each is also reported as a diagnostic).
    private func scanForbiddenStrtod(root: URL, shippedTargets: [String]) -> Bool {
        var found = false
        for target in shippedTargets {
            let lib = root.appending(path: target)
            guard let walker = FileManager.default.enumerator(at: lib, includingPropertiesForKeys: nil) else {
                continue
            }
            while let file = walker.nextObject() as? URL {
                guard file.pathExtension == "swift",
                    let text = try? String(contentsOf: file, encoding: .utf8)
                else { continue }
                for (offset, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
                // A reviewed exception opts out with a trailing `// lint:allow` marker.
                where line.contains("strtod(") && !line.contains("lint:allow") {
                    Diagnostics.error(
                        "\(file.lastPathComponent):\(offset + 1): locale-sensitive strtod is banned in shipped "
                            + "library code (annotate a reviewed case with // lint:allow)")
                    found = true
                }
            }
        }
        return found
    }

    /// Scans the package's `Tests/` tree for the AD-family's test-discipline bans (Phase 6), modeled on
    /// the grep-based `scanForbiddenStrtod`:
    ///   - **inline PRNG re-rolls** (`struct SplitMix64` / `struct LCG`) — use `ADTestKit.SeededRNG`;
    ///   - **untyped `#expect(throws:)`** (`(any Error).self` / `Error.self`) — use the kit's
    ///     `expectThrows(_:where:)` with a concrete error type and payload predicate;
    ///   - **wall-clock assertions** (`#expect`/`#require` over `DispatchTime` / `ContinuousClock` /
    ///     `Date` elapsed) — assert allocation / op counts, or quarantine with
    ///     `withKnownIssue(isIntermittent:)`.
    /// Each category is gated by a `.adbuildtools.json` toggle (default on) and a per-line `// lint:allow`
    /// escape. Returns true if any un-annotated violation is found (each reported as a diagnostic).
    private func scanTestTreeDiscipline(root: URL, settings: LintSettings) -> Bool {
        guard settings.prngBan || settings.untypedThrowsBan || settings.wallClockBan else { return false }
        let tests = root.appending(path: "Tests")
        guard FileManager.default.fileExists(atPath: tests.path),
            let walker = FileManager.default.enumerator(at: tests, includingPropertiesForKeys: nil)
        else { return false }
        let wallClockTokens = [
            "DispatchTime", "ContinuousClock", "SuspendingClock", ".timeIntervalSince", ".uptimeNanoseconds"
        ]
        var found = false
        while let file = walker.nextObject() as? URL {
            guard file.pathExtension == "swift",
                let text = try? String(contentsOf: file, encoding: .utf8)
            else { continue }
            for (offset, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                // A reviewed exception opts out with a trailing `// lint:allow` marker.
                if line.contains("lint:allow") { continue }
                let loc = "\(file.lastPathComponent):\(offset + 1)"
                if settings.prngBan, line.contains("struct SplitMix64") || line.contains("struct LCG") {
                    Diagnostics.error(
                        "\(loc): inline PRNG re-roll is banned in tests — use ADTestKit.SeededRNG "
                            + "(annotate a reviewed case with // lint:allow)")
                    found = true
                }
                if settings.untypedThrowsBan,
                    line.contains("#expect(throws: (any Error).self)")
                        || line.contains("#expect(throws: Error.self)")
                {
                    Diagnostics.error(
                        "\(loc): untyped #expect(throws:) is banned in tests — use "
                            + "ADTestKit.expectThrows(_:where:) with a concrete error type (// lint:allow to opt out)")
                    found = true
                }
                if settings.wallClockBan, line.contains("#expect(") || line.contains("#require("),
                    wallClockTokens.contains(where: { line.contains($0) })
                {
                    Diagnostics.error(
                        "\(loc): wall-clock assertion is banned in tests — assert allocations/op-counts or "
                            + "quarantine with withKnownIssue(isIntermittent:) (// lint:allow to opt out)")
                    found = true
                }
            }
        }
        return found
    }
}

/// Consumer-specific lint configuration, read from `.adbuildtools.json` with safe defaults.
private struct LintSettings {
    let shippedTargets: [String]
    let strtodBan: Bool
    /// The shipped force-unwrap / force-try AST pass. Defaults on; a repo whose force-unwrap cleanup is
    /// still staged sets this `false` in `.adbuildtools.json` to adopt the rest of the standard now.
    let forceUnwrapBan: Bool
    /// Test-tree discipline toggles (Phase 6), each default on. A repo opts a category out in
    /// `.adbuildtools.json` (e.g. `"wallClockBan": false`) while still adopting the rest.
    let prngBan: Bool
    let untypedThrowsBan: Bool
    let wallClockBan: Bool

    init(root: URL) {
        let file = root.appending(path: ".adbuildtools.json")
        let json =
            (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) }
            as? [String: Any]
        shippedTargets = (json?["shippedTargets"] as? [String]) ?? ["Sources"]
        strtodBan = (json?["strtodBan"] as? Bool) ?? true
        forceUnwrapBan = (json?["forceUnwrapBan"] as? Bool) ?? true
        prngBan = (json?["prngBan"] as? Bool) ?? true
        untypedThrowsBan = (json?["untypedThrowsBan"] as? Bool) ?? true
        wallClockBan = (json?["wallClockBan"] as? Bool) ?? true
    }
}

private enum LintError: Error, CustomStringConvertible {
    case failed
    var description: String { "lint failed" }
}

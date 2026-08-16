import Foundation
import PackagePlugin

/// Formats the package in place with the toolchain's bundled `swift-format`.
///
/// Driven through the `swift format` subcommand (`swift package format`); configuration is read from the
/// consumer's `.swift-format`, kept in sync with the canonical ADBuildTools copy via `scripts/sync-config.sh`
/// and the CI drift check.
@main
struct FormatPlugin: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        let root = context.package.directoryURL
        let candidates = ["Sources", "Tests", "Plugins", "Package.swift"]
        let paths = candidates.map { root.appending(path: $0) }
            .filter {
                FileManager.default.fileExists(atPath: $0.path)
            }
        guard !paths.isEmpty else {
            Diagnostics.warning("nothing to format (no Sources/Tests/Plugins/Package.swift found)")
            return
        }

        let swift = try context.tool(named: "swift")
        let process = Process()
        process.executableURL = swift.url
        process.arguments = ["format", "--in-place", "--recursive"] + paths.map(\.path)
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus == 0 {
            print("Formatted \(paths.map(\.lastPathComponent).joined(separator: ", ")).")
        } else {
            Diagnostics.error("swift format exited with status \(process.terminationStatus)")
        }
    }
}

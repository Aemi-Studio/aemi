import Foundation
import PackagePlugin

/// Enforces formatting during the build by running `swift format lint --strict` as a prebuild step.
///
/// A non-zero exit fails the build. Consumers attach it to library targets only when their `*_DEV` env var
/// is set (see each Package.swift), so it never runs for packages that merely depend on them. swift-format
/// auto-discovers the consumer's `.swift-format`.
@main
struct LintBuildPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        guard let module = target.sourceModule else { return [] }
        let swiftFiles = module.sourceFiles(withSuffix: "swift").map(\.url.path)
        guard !swiftFiles.isEmpty else { return [] }

        let swift = try context.tool(named: "swift")
        return [
            .prebuildCommand(
                displayName: "swift format lint (\(target.name))",
                executable: swift.url,
                arguments: ["format", "lint", "--strict"] + swiftFiles,
                outputFilesDirectory: context.pluginWorkDirectoryURL)
        ]
    }
}

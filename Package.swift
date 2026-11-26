// swift-tools-version: 6.3
import CompilerPluginSupport
import PackageDescription

let strictCSettings: [CSetting] = [
    .unsafeFlags([
        "-std=c11", "-Wall", "-Wextra", "-Wpedantic", "-Wconversion", "-Wsign-conversion",
        "-Wcast-qual", "-Wstrict-prototypes", "-Wmissing-prototypes", "-Wshadow", "-Wundef",
        "-Wvla", "-Wwrite-strings", "-Wformat=2", "-Wswitch-enum", "-Wimplicit-fallthrough",
        "-Wdouble-promotion", "-Werror"
    ])
]

let strictSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .treatAllWarnings(as: .error),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("MemberImportVisibility")
]

#if compiler(>=6.4)
    let kernelSettings: [SwiftSetting] =
        strictSettings + [.strictMemorySafety(), .enableExperimentalFeature("Lifetimes")]
#else
    let kernelSettings: [SwiftSetting] =
        strictSettings + [.enableExperimentalFeature("Lifetimes")]
#endif

let typeCheckBudgetMS = Context.environment["AEMI_TYPECHECK_BUDGET_MS"].flatMap { Int($0) } ?? 100
let timingWarningFlags: [SwiftSetting] = [
    .unsafeFlags([
        "-Xfrontend", "-warn-long-function-bodies=\(typeCheckBudgetMS)",
        "-Xfrontend", "-warn-long-expression-type-checking=\(typeCheckBudgetMS)"
    ])
]

let testSettings: [SwiftSetting] =
    strictSettings + timingWarningFlags + [.unsafeFlags(["-enable-actor-data-race-checks"])]

let appSettings: [SwiftSetting] = [
    .strictMemorySafety(),
    .enableExperimentalFeature("StrictConcurrency"),
    .swiftLanguageMode(.v6)
]

let isDev = Context.environment["AEMI_DEV"] != nil

let isFuzz = Context.environment["AEMI_FUZZ"] != nil

var packageDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/swiftlang/swift-syntax.git", "603.0.0" ..< "605.0.0"),
    .package(url: "https://github.com/apple/swift-collections.git", from: "1.7.3"),
    .package(url: "https://github.com/apple/swift-system.git", from: "1.8.1"),
    .package(url: "https://github.com/apple/swift-crypto.git", "5.1.2" ..< "6.0.0"),
    .package(url: "https://github.com/apple/swift-log.git", from: "1.16.2")
]
if isDev {
    packageDependencies.append(
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.5.0")
    )
    packageDependencies.append(
        .package(url: "https://github.com/ordo-one/benchmark", from: "1.38.0")
    )
}

let libraryBuildPlugins: [Target.PluginUsage] = isDev ? [.plugin(name: "LintBuild")] : []

let heapModule: Target.Dependency = .product(name: "HeapModule", package: "swift-collections")
let systemPackage: Target.Dependency = .product(name: "SystemPackage", package: "swift-system")

let package = Package(
    name: "Aemi",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
        .watchOS(.v11),
        .tvOS(.v18),
        .visionOS(.v2)
    ],
    products: [
        .library(name: "Aemi", targets: ["Aemi"]),
        .library(name: "AemiCore", targets: ["AemiCore"]),
        .library(name: "AemiUI", targets: ["AemiUI"]),
        .library(name: "AemiTesting", targets: ["AemiTesting"]),
        .library(name: "InternedStrings", targets: ["InternedStrings"]),
        .library(name: "Loggable", targets: ["Loggable"]),
        .library(name: "AemiFoundation", targets: ["AemiFoundation"]),
        .library(name: "AemiTestKit", targets: ["AemiTestKit", "AemiTestKitSeams"]),
        .library(name: "CAemiKernels", targets: ["CAemiKernels"]),
        .library(name: "CAemiTestKitMalloc", targets: ["CAemiTestKitMalloc"]),
        .library(name: "AemiKernel", targets: ["AemiKernel"]),
        .library(name: "AemiKernels", targets: ["AemiKernels"]),
        .library(name: "AemiUnicode", targets: ["AemiUnicode"]),
        .library(name: "AemiText", targets: ["AemiText"]),
        .library(name: "AemiIO", targets: ["AemiIO"]),
        .library(name: "AemiFileSystem", targets: ["AemiFileSystem"]),
        .library(name: "AemiInterner", targets: ["AemiInterner"]),
        .library(name: "AemiMetrics", targets: ["AemiMetrics"]),
        .library(name: "AemiProcess", targets: ["AemiProcess"]),
        .library(name: "AemiLexers", targets: ["AemiLexers"]),
        .library(name: "AemiDiff", targets: ["AemiDiff"]),
        .library(name: "AemiArgon2", targets: ["AemiArgon2"]),
        .library(name: "AemiDigest", targets: ["AemiDigest"]),
        .library(name: "AemiRuntime", targets: ["AemiRuntime"]),
        .library(name: "AemiMacroSupport", targets: ["AemiMacroSupport"]),
        .library(name: "AemiTestKitSeams", targets: ["AemiTestKitSeams"])
    ],
    dependencies: packageDependencies,
    targets: [
        .macro(
            name: "AemiMacros",
            dependencies: [
                .product(name: "SwiftBasicFormat", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftDiagnostics", package: "swift-syntax"),
                .product(name: "SwiftOperators", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftParserDiagnostics", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacroExpansion", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax")
            ]
        ),
        .target(
            name: "Aemi",
            dependencies: ["AemiCore", "AemiUI", "InternedStrings", "Loggable"],
            swiftSettings: appSettings
        ),
        .target(name: "AemiCore", swiftSettings: appSettings),
        .target(name: "AemiUI", dependencies: ["AemiCore"], swiftSettings: appSettings),
        .target(name: "AemiTesting", dependencies: ["AemiCore"], swiftSettings: appSettings),
        .target(name: "InternedStrings", dependencies: ["AemiMacros"], swiftSettings: appSettings),
        .target(
            name: "Loggable",
            dependencies: [
                "AemiMacros",
                // Apple platforms log through os.Logger; everywhere else through swift-log.
                .product(
                    name: "Logging",
                    package: "swift-log",
                    condition: .when(platforms: [.linux, .windows, .android, .wasi, .openbsd])
                )
            ],
            swiftSettings: appSettings
        ),

        .target(
            name: "AemiKernel",
            dependencies: ["AemiKernels"],
            swiftSettings: kernelSettings,
            plugins: libraryBuildPlugins
        ),
        .target(name: "CAemiCPU", cSettings: strictCSettings),
        .target(name: "CAemiKernels", dependencies: ["CAemiCPU"], cSettings: strictCSettings),
        .target(
            name: "AemiKernels",
            dependencies: ["CAemiKernels"],
            swiftSettings: kernelSettings,
            plugins: libraryBuildPlugins
        ),
        .executableTarget(
            name: "AemiKernelsProbe",
            dependencies: ["AemiKernels"],
            swiftSettings: strictSettings
        ),
        .executableTarget(
            name: "AemiCodecProbe",
            dependencies: ["AemiKernel", "AemiKernels"],
            swiftSettings: strictSettings
        ),
        .target(
            name: "AemiUnicode",
            dependencies: ["AemiKernel"],
            swiftSettings: strictSettings,
            plugins: libraryBuildPlugins
        ),
        .target(
            name: "AemiText",
            dependencies: ["AemiKernel", "AemiKernels", "AemiUnicode"],
            swiftSettings: strictSettings,
            plugins: libraryBuildPlugins
        ),
        .target(
            name: "AemiIO",
            dependencies: ["AemiKernel"],
            swiftSettings: kernelSettings,
            plugins: libraryBuildPlugins
        ),
        .target(
            name: "AemiFileSystem",
            dependencies: ["AemiIO"],
            swiftSettings: kernelSettings,
            plugins: libraryBuildPlugins
        ),
        .target(
            name: "AemiInterner",
            dependencies: ["AemiKernel"],
            swiftSettings: kernelSettings,
            plugins: libraryBuildPlugins
        ),
        .target(name: "AemiMetrics", swiftSettings: strictSettings, plugins: libraryBuildPlugins),
        .target(name: "AemiProcess", swiftSettings: kernelSettings, plugins: libraryBuildPlugins),
        .target(name: "AemiLexers", swiftSettings: strictSettings, plugins: libraryBuildPlugins),
        .target(
            name: "AemiDiff",
            dependencies: ["AemiKernel", "AemiText", "AemiLexers"],
            swiftSettings: strictSettings,
            plugins: libraryBuildPlugins
        ),
        .target(
            name: "CAemiArgon2",
            dependencies: ["CAemiCPU"],
            cSettings: strictCSettings + [.unsafeFlags(["-O3"], .when(configuration: .release))]
        ),
        .target(
            name: "AemiArgon2",
            dependencies: ["CAemiArgon2"],
            swiftSettings: strictSettings,
            plugins: libraryBuildPlugins
        ),
        .target(
            name: "AemiDigest",
            dependencies: [
                "AemiKernel",
                .product(
                    name: "Crypto",
                    package: "swift-crypto",
                    condition: .when(platforms: [.linux, .android, .windows, .openbsd, .wasi])
                )
            ],
            swiftSettings: strictSettings,
            plugins: libraryBuildPlugins
        ),
        .target(name: "AemiRuntime", swiftSettings: strictSettings, plugins: libraryBuildPlugins),
        .target(
            name: "AemiFoundation",
            dependencies: [
                "AemiKernel", "AemiKernels", "AemiIO", "AemiText", "AemiUnicode", "AemiMetrics",
                "AemiProcess", "AemiRuntime"
            ],
            swiftSettings: strictSettings,
            plugins: libraryBuildPlugins
        ),

        .target(
            name: "AemiMacroSupport",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftDiagnostics", package: "swift-syntax")
            ],
            swiftSettings: strictSettings,
            plugins: libraryBuildPlugins
        ),

        .target(name: "CAemiTestKitMalloc", cSettings: strictCSettings),
        .target(
            name: "AemiTestKitSeams",
            dependencies: ["AemiRuntime"],
            swiftSettings: strictSettings,
            plugins: libraryBuildPlugins
        ),
        .target(
            name: "AemiTestKit",
            dependencies: ["AemiKernel", "AemiTestKitSeams", "CAemiTestKitMalloc", heapModule, systemPackage],
            swiftSettings: strictSettings,
            plugins: libraryBuildPlugins
        ),

        .testTarget(
            name: "AemiCoreTests",
            dependencies: ["AemiCore"],
            swiftSettings: appSettings
        ),
        .testTarget(
            name: "AemiTestingTests",
            dependencies: ["AemiCore", "AemiTesting", "AemiTestKit"],
            swiftSettings: appSettings
        ),
        .testTarget(
            name: "InternedStringsTests",
            dependencies: [
                "InternedStrings", "AemiMacros",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax")
            ],
            swiftSettings: appSettings
        ),
        .testTarget(
            name: "LoggableTests",
            dependencies: [
                "Loggable", "AemiMacros",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax")
            ],
            swiftSettings: appSettings
        ),

        .testTarget(
            name: "AemiKernelTests",
            dependencies: ["AemiKernel", "AemiTestKit"],
            swiftSettings: testSettings
        ),
        .testTarget(
            name: "AemiKernelsTests",
            dependencies: ["AemiKernels", "AemiTestKit"],
            swiftSettings: testSettings
        ),
        .testTarget(
            name: "AemiUnicodeTests",
            dependencies: ["AemiUnicode"],
            swiftSettings: testSettings
        ),
        .testTarget(
            name: "AemiTextTests",
            dependencies: ["AemiText", "AemiTestKit"],
            swiftSettings: testSettings
        ),
        .testTarget(name: "AemiIOTests", dependencies: ["AemiIO"], swiftSettings: testSettings),
        .testTarget(
            name: "AemiFileSystemTests",
            dependencies: ["AemiFileSystem", "AemiIO"],
            swiftSettings: testSettings
        ),
        .testTarget(
            name: "AemiInternerTests",
            dependencies: ["AemiInterner", "AemiKernel", "AemiTestKit"],
            swiftSettings: testSettings
        ),
        .testTarget(
            name: "AemiMetricsTests",
            dependencies: ["AemiMetrics"],
            swiftSettings: testSettings
        ),
        .testTarget(name: "AemiProcessTests", dependencies: ["AemiProcess"], swiftSettings: testSettings),
        .testTarget(
            name: "AemiLexersTests",
            dependencies: ["AemiLexers", "AemiTestKit"],
            swiftSettings: testSettings
        ),
        .testTarget(name: "CAemiCPUTests", dependencies: ["CAemiCPU"], swiftSettings: testSettings),
        .testTarget(
            name: "AemiDigestTests",
            dependencies: ["AemiDigest", "AemiKernel"],
            swiftSettings: testSettings
        ),
        .testTarget(
            name: "AemiArgon2Tests",
            dependencies: ["AemiArgon2", "CAemiArgon2", "AemiTestKit"],
            swiftSettings: testSettings
        ),
        .testTarget(
            name: "AemiDiffTests",
            dependencies: ["AemiDiff", "AemiText", "AemiTestKit"],
            swiftSettings: testSettings
        ),
        .testTarget(
            name: "AemiMacroSupportTests",
            dependencies: ["AemiMacroSupport"],
            swiftSettings: testSettings
        ),
        .testTarget(
            name: "AemiRuntimeTests",
            dependencies: ["AemiRuntime", "AemiTestKit"],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "AemiFoundationTests",
            dependencies: ["AemiFoundation"],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "AemiTestKitTests",
            dependencies: ["AemiTestKit", "AemiTestKitSeams"],
            swiftSettings: strictSettings
        )
    ]
)

package.products.append(contentsOf: [
    .plugin(name: "Format", targets: ["Format"]),
    .plugin(name: "Lint", targets: ["Lint"]),
    .plugin(name: "LintBuild", targets: ["LintBuild"])
])
package.targets.append(contentsOf: [
    .plugin(
        name: "Format",
        capability: .command(
            intent: .custom(verb: "format", description: "Format Swift sources with swift-format"),
            permissions: [
                .writeToPackageDirectory(reason: "Format Swift sources with swift-format")
            ]
        )
    ),
    .plugin(
        name: "Lint",
        capability: .command(
            intent: .custom(
                verb: "lint",
                description: "Check formatting and shipped-library discipline"
            )
        )
    ),
    .plugin(name: "LintBuild", capability: .buildTool())
])

if isFuzz {
    package.targets.append(
        .executableTarget(
            name: "AemiKernelsFuzz",
            dependencies: ["AemiKernels"],
            swiftSettings: strictSettings + [
                .unsafeFlags(["-parse-as-library", "-sanitize=fuzzer"])
            ]
        )
    )
    package.products.append(.executable(name: "AemiKernelsFuzz", targets: ["AemiKernelsFuzz"]))
}

if isDev {
    package.targets.append(
        .executableTarget(
            name: "AemiFoundationSuite",
            dependencies: [
                "AemiKernel", "AemiText", "AemiKernels", "AemiFileSystem", "AemiInterner",
                .product(name: "Benchmark", package: "benchmark")
            ],
            path: "Benchmarks/AemiFoundationSuite",
            swiftSettings: strictSettings,
            plugins: [.plugin(name: "BenchmarkPlugin", package: "benchmark")]
        )
    )
}

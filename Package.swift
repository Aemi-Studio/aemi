// swift-tools-version: 6.3
import CompilerPluginSupport
import PackageDescription

// Aemi — the kernel package of the Aemi ecosystem.
//
// ONE package, MANY small targets (link exactly what you need), with two umbrella products:
//   • `import AemiFoundation` — every zero-dependency RUNTIME tier (byte/number kernel, Unicode,
//     text, POSIX IO, process metrics, and the concurrency seams/pools).
//   • the `AemiTestKit` product — the deterministic-testing kit (AemiTestKit + AemiTestKitSeams).
// Plus the pre-existing app-level tiers: Aemi, AemiCore, AemiUI, AemiTesting, InternedStrings,
// Loggable. Absorbed from ADFoundation (runtime tiers + test kit) and ADBuildTools (Format/Lint/
// LintBuild plugins, canonical configs, quality scripts), with modules renamed AD* → Aemi*.
//
// NOTE: AemiRuntime (kernel-tier pools/seams) and AemiCore (app-level TaskProvider/TaskRole) are
// deliberately SEPARATE modules and are never both re-exported from a single umbrella target.
// Likewise AemiTesting (app-level) and AemiTestKit (kernel test kit) stay separate products.

// ── Settings tiers (kernel targets, absorbed from ADFoundation) ──
// Strict, dependency-safe settings applied to every kernel-tier Swift target. `.v6` turns on
// complete strict-concurrency checking; the upcoming features tighten existentials (`any`) and
// import visibility.
let strictSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .treatAllWarnings(as: .error),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("MemberImportVisibility")
]

// The byte/IO kernel additionally adopts SE-0458 strict memory safety + the compile-time-only
// `Lifetimes` feature. Applied to the pointer/POSIX targets (AemiKernel, AemiKernels, AemiIO).
let kernelSettings: [SwiftSetting] =
    strictSettings + [.strictMemorySafety(), .enableExperimentalFeature("Lifetimes")]

// Compile-time type-check timing warnings — unsafe flags, so they live only on test targets.
// The budget is env-tunable (AEMI_TYPECHECK_BUDGET_MS) because `treatAllWarnings(as: .error)`
// turns an overrun into a HARD build error while the measured quantity is type-check WALL TIME —
// structurally flaky on shared CI runners. CI exports a higher budget; unset it stays 100.
let typeCheckBudgetMS = Context.environment["AEMI_TYPECHECK_BUDGET_MS"].flatMap { Int($0) } ?? 100
let timingWarningFlags: [SwiftSetting] = [
    .unsafeFlags([
        "-Xfrontend", "-warn-long-function-bodies=\(typeCheckBudgetMS)",
        "-Xfrontend", "-warn-long-expression-type-checking=\(typeCheckBudgetMS)"
    ])
]

// Kernel tests: strict + timing warnings + runtime actor data-race checks.
let testSettings: [SwiftSetting] =
    strictSettings + timingWarningFlags + [.unsafeFlags(["-enable-actor-data-race-checks"])]

// Settings for the pre-existing app-level targets (Aemi, AemiCore, AemiUI, AemiTesting,
// InternedStrings, Loggable) — preserved as-is from the original Aemi manifest.
let appSettings: [SwiftSetting] = [
    .strictMemorySafety(),
    .enableExperimentalFeature("StrictConcurrency"),
    .swiftLanguageMode(.v6)
]

// Dev-only tooling is gated behind `AEMI_DEV` so consumers never resolve it.
let isDev = Context.environment["AEMI_DEV"] != nil

// The libFuzzer kernel target is gated behind `AEMI_FUZZ` so the default build never links a
// `main`-less `-sanitize=fuzzer` executable (a Linux capability of the toolchain — the Darwin SDK
// rejects it). See `Sources/AemiKernelsFuzz`.
let isFuzz = Context.environment["AEMI_FUZZ"] != nil

// Non-dev dependencies:
//   • swift-syntax      — backs AemiMacros and AemiMacroSupport (macro-plugin helpers).
//   • swift-collections — `HeapModule` backs the AemiTestKit `TestClock` sleeper queue.
//   • swift-system      — `SystemPackage` backs AemiTestKit's typed temp-file paths.
var packageDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "603.0.0"),
    .package(url: "https://github.com/apple/swift-collections.git", from: "1.6.0"),
    .package(url: "https://github.com/apple/swift-system.git", from: "1.7.2")
]
if isDev {
    packageDependencies.append(
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.0.0"))
    // ordo-one benchmark suite (`AEMI_DEV=1 swift package benchmark`).
    packageDependencies.append(
        .package(url: "https://github.com/ordo-one/benchmark", from: "1.4.0"))
}

// The in-package LintBuild plugin runs `swift format lint --strict` as a prebuild step on the
// kernel library targets — dev-gated so consumers never run it.
let libraryBuildPlugins: [Target.PluginUsage] = isDev ? [.plugin(name: "LintBuild")] : []

let heapModule: Target.Dependency = .product(name: "HeapModule", package: "swift-collections")
let systemPackage: Target.Dependency = .product(name: "SystemPackage", package: "swift-system")

let package = Package(
    name: "Aemi",
    // Family floor: `Synchronization` (Mutex/Atomic) ships in macOS 15 / iOS 18 / tvOS 18 /
    // watchOS 11 / visionOS 2.
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
        .watchOS(.v11),
        .tvOS(.v18),
        .visionOS(.v2)
    ],
    products: [
        // ── Pre-existing app-level products ──
        .library(name: "Aemi", targets: ["Aemi"]),
        .library(name: "AemiCore", targets: ["AemiCore"]),
        .library(name: "AemiUI", targets: ["AemiUI"]),
        .library(name: "AemiTesting", targets: ["AemiTesting"]),
        .library(name: "InternedStrings", targets: ["InternedStrings"]),
        .library(name: "Loggable", targets: ["Loggable"]),
        // ── Kernel tiers (absorbed from ADFoundation) ──
        // Runtime umbrella: `import AemiFoundation` → every zero-dependency runtime tier.
        .library(name: "AemiFoundation", targets: ["AemiFoundation"]),
        // Test umbrella product: the deterministic-testing kit (+ seams).
        .library(name: "AemiTestKit", targets: ["AemiTestKit", "AemiTestKitSeams"]),
        // Individual runtime tiers — link exactly what you need.
        .library(name: "AemiKernel", targets: ["AemiKernel"]),
        // Runtime-dispatched SIMD byte kernels (JSON string scan, ASCII fold, byte search).
        .library(name: "AemiKernels", targets: ["AemiKernels"]),
        .library(name: "AemiUnicode", targets: ["AemiUnicode"]),
        .library(name: "AemiText", targets: ["AemiText"]),
        .library(name: "AemiIO", targets: ["AemiIO"]),
        .library(name: "AemiMetrics", targets: ["AemiMetrics"]),
        // Concurrency seams + pools (formerly ADConcurrency).
        .library(name: "AemiRuntime", targets: ["AemiRuntime"]),
        // Shared swift-syntax helpers for macro compiler plugins. Never re-exported by an umbrella.
        .library(name: "AemiMacroSupport", targets: ["AemiMacroSupport"]),
        .library(name: "AemiTestKitSeams", targets: ["AemiTestKitSeams"])
    ],
    dependencies: packageDependencies,
    targets: [
        // ── Pre-existing app-level targets ──
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
        .target(name: "Loggable", dependencies: ["AemiMacros"], swiftSettings: appSettings),

        // ── Kernel runtime tiers (absorbed from ADFoundation) ──
        // AemiKernel — pointer-level byte primitives; SE-0458 strict memory safety. Depends on
        // AemiKernels for the shared runtime-dispatched SIMD scans. Acyclic: AemiKernels →
        // CAemiKernels only.
        .target(
            name: "AemiKernel", dependencies: ["AemiKernels"], swiftSettings: kernelSettings,
            plugins: libraryBuildPlugins),
        // CAemiKernels — runtime-dispatched SIMD byte kernels in C (per-function
        // `__attribute__((target))` + `pthread_once` feature probe).
        .target(name: "CAemiKernels"),
        // AemiKernels — the pure-Swift facade over CAemiKernels; strict-memory-safe like AemiKernel.
        .target(
            name: "AemiKernels", dependencies: ["CAemiKernels"], swiftSettings: kernelSettings,
            plugins: libraryBuildPlugins),
        // AemiKernelsProbe — standalone differential check (kernels vs scalar reference) + ISA-tier
        // printer (`swift run --arch x86_64 AemiKernelsProbe` under Rosetta).
        .executableTarget(
            name: "AemiKernelsProbe", dependencies: ["AemiKernels"], swiftSettings: strictSettings),
        .target(
            name: "AemiUnicode", dependencies: ["AemiKernel"], swiftSettings: strictSettings,
            plugins: libraryBuildPlugins),
        .target(
            name: "AemiText", dependencies: ["AemiKernel", "AemiUnicode"],
            swiftSettings: strictSettings, plugins: libraryBuildPlugins),
        .target(
            name: "AemiIO", dependencies: ["AemiKernel"], swiftSettings: kernelSettings,
            plugins: libraryBuildPlugins),
        .target(name: "AemiMetrics", swiftSettings: strictSettings, plugins: libraryBuildPlugins),
        // AemiRuntime — zero-dep production seams (TaskProvider/Clock) + ResourcePool /
        // BlockingOffloadPool. Separate from AemiCore's app-level TaskProvider/TaskRole.
        .target(name: "AemiRuntime", swiftSettings: strictSettings, plugins: libraryBuildPlugins),
        // Runtime umbrella — re-exports every kernel runtime tier (NOT AemiMacroSupport:
        // swift-syntax stays opt-in; NOT AemiCore: app tier stays separate).
        .target(
            name: "AemiFoundation",
            dependencies: [
                "AemiKernel", "AemiKernels", "AemiIO", "AemiText", "AemiUnicode", "AemiMetrics",
                "AemiRuntime"
            ],
            swiftSettings: strictSettings, plugins: libraryBuildPlugins),

        // ── Macro support (the one swift-syntax kernel tier) ──
        .target(
            name: "AemiMacroSupport",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftDiagnostics", package: "swift-syntax")
            ],
            swiftSettings: strictSettings,
            plugins: libraryBuildPlugins),

        // ── Kernel test tooling ──
        // CAemiTestKitMalloc — C shim exposing process-wide heap-allocation counting.
        .target(name: "CAemiTestKitMalloc"),
        // AemiTestKitSeams — stable re-export of the AemiRuntime seams.
        .target(
            name: "AemiTestKitSeams", dependencies: ["AemiRuntime"],
            swiftSettings: strictSettings, plugins: libraryBuildPlugins),
        // AemiTestKit — the deterministic-testing kit (Testing-backed asserts, SeededRNG, Fuzz,
        // oracles, TestClock/AsyncProbe, gates).
        .target(
            name: "AemiTestKit",
            dependencies: ["AemiTestKitSeams", "CAemiTestKitMalloc", heapModule, systemPackage],
            swiftSettings: strictSettings, plugins: libraryBuildPlugins),

        // ── Pre-existing app-level tests ──
        .testTarget(
            name: "AemiCoreTests", dependencies: ["AemiCore"], swiftSettings: appSettings),
        .testTarget(
            name: "AemiTestingTests", dependencies: ["AemiCore", "AemiTesting"],
            swiftSettings: appSettings),
        .testTarget(
            name: "InternedStringsTests",
            dependencies: [
                "InternedStrings", "AemiMacros",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax")
            ],
            swiftSettings: appSettings),
        .testTarget(
            name: "LoggableTests",
            dependencies: [
                "Loggable", "AemiMacros",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax")
            ],
            swiftSettings: appSettings),

        // ── Kernel tests (ported from ADFoundation) ──
        .testTarget(
            name: "AemiKernelTests", dependencies: ["AemiKernel", "AemiTestKit"],
            swiftSettings: testSettings),
        .testTarget(
            name: "AemiKernelsTests", dependencies: ["AemiKernels", "AemiTestKit"],
            swiftSettings: testSettings),
        .testTarget(
            name: "AemiUnicodeTests", dependencies: ["AemiUnicode"], swiftSettings: testSettings),
        .testTarget(
            name: "AemiTextTests", dependencies: ["AemiText", "AemiTestKit"],
            swiftSettings: testSettings),
        .testTarget(name: "AemiIOTests", dependencies: ["AemiIO"], swiftSettings: testSettings),
        .testTarget(
            name: "AemiMetricsTests", dependencies: ["AemiMetrics"], swiftSettings: testSettings),
        .testTarget(
            name: "AemiMacroSupportTests", dependencies: ["AemiMacroSupport"],
            swiftSettings: testSettings),
        // Folded suites keep their origin settings (no aggressive type-check timing gate).
        .testTarget(
            name: "AemiRuntimeTests", dependencies: ["AemiRuntime", "AemiTestKit"],
            swiftSettings: strictSettings),
        .testTarget(
            name: "AemiFoundationTests", dependencies: ["AemiFoundation"],
            swiftSettings: strictSettings),
        .testTarget(
            name: "AemiTestKitTests", dependencies: ["AemiTestKit", "AemiTestKitSeams"],
            swiftSettings: strictSettings)
    ]
)

// Consumers select these dependency-free plugins with their own development flags.
// AEMI_DEV controls attachment to Aemi's targets, not availability to other packages.
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
            ])),
    .plugin(
        name: "Lint",
        capability: .command(
            intent: .custom(
                verb: "lint", description: "Check formatting and shipped-library discipline"))),
    .plugin(name: "LintBuild", capability: .buildTool())
])

// libFuzzer kernel target (AEMI_FUZZ-gated; Linux-CI-only — `-sanitize=fuzzer` is Darwin-rejected).
if isFuzz {
    package.targets.append(
        .executableTarget(
            name: "AemiKernelsFuzz",
            dependencies: ["AemiKernels"],
            swiftSettings: strictSettings + [
                .unsafeFlags(["-parse-as-library", "-sanitize=fuzzer"])
            ]))
    package.products.append(.executable(name: "AemiKernelsFuzz", targets: ["AemiKernelsFuzz"]))
}

// ordo-one benchmark suite (AEMI_DEV-gated).
if isDev {
    package.targets.append(
        .executableTarget(
            name: "AemiFoundationSuite",
            dependencies: [
                "AemiKernel", "AemiText", "AemiKernels",
                .product(name: "Benchmark", package: "benchmark")
            ],
            path: "Benchmarks/AemiFoundationSuite",
            swiftSettings: strictSettings,
            plugins: [.plugin(name: "BenchmarkPlugin", package: "benchmark")]))
}

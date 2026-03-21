// swift-tools-version: 6.2
import CompilerPluginSupport
import PackageDescription

private let package = Package(
    name: "Aemi",
    platforms: [
        .iOS(.v14),
        .macOS(.v11),
    ],
    products: [
        .library(
            name: "Aemi",
            targets: [
                "Aemi"
            ]
        ),
        .library(
            name: "InternedStrings",
            targets: [
                "InternedStrings"
            ]
        ),
        .library(
            name: "Loggable",
            targets: [
                "Loggable"
            ]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "602.0.0")
    ],
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
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
            ]
        ),
        .target(
            name: "Aemi",
            dependencies: [
                "InternedStrings",
                "Loggable",
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "InternedStrings",
            dependencies: [
                "AemiMacros"
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "Loggable",
            dependencies: [
                "AemiMacros"
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "InternedStringsTests",
            dependencies: [
                "InternedStrings",
                "AemiMacros",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "LoggableTests",
            dependencies: [
                "Loggable",
                "AemiMacros",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ],
            swiftSettings: swiftSettings
        ),
    ]
)

private let swiftSettings: [SwiftSetting] = [
    .strictMemorySafety(),
    .enableExperimentalFeature("StrictConcurrency"),
    .swiftLanguageMode(.version("6.2")),
]

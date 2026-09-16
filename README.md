# Aemi

Shared Swift building blocks for applications, libraries, and developer tools.

Aemi provides typed identifiers, concurrency utilities, byte and text primitives,
macros, SwiftUI helpers, and deterministic test support. Choose the products your
target uses; a command-line parser does not need to link UI code, and an application
does not need to ship its test tools.

## Requirements

- Swift 6.3 or later, in Swift 6 language mode.
- Apple platforms: iOS 18, macOS 15, tvOS 18, watchOS 11, and visionOS 2.
- The kernel/runtime products also support Linux. SwiftUI and Combine APIs require
  their Apple frameworks.

## Add Aemi

Declare the remote package and select products on each target:

```swift
dependencies: [
    .package(url: "https://github.com/Aemi-Studio/aemi.git", branch: "main")
],
targets: [
    .target(
        name: "MyFeature",
        dependencies: [.product(name: "AemiCore", package: "aemi")]
    ),
    .testTarget(
        name: "MyFeatureTests",
        dependencies: [
            "MyFeature",
            .product(name: "AemiTesting", package: "aemi")
        ]
    )
]
```

For example, give identifiers a type that describes what they identify:

```swift
import AemiCore

enum User {}
enum Document {}

let userID = Identifier<User, String>("user-42")
let documentID = Identifier<Document, String>("document-42")
```

The two identifiers have different types, even though both store a `String`.
`Identifier` supports `Hashable` and `Codable` when its raw value does.

## Choose a product

### Applications

| Product | Provides |
| --- | --- |
| `AemiCore` | Typed identifiers, projections, task providers, throttling, and collection helpers. |
| `AemiUI` | SwiftUI presentation, layout, visibility, and haptics helpers. Depends on `AemiCore`. |
| `InternedStrings` | Attached and expression macros for string obfuscation. |
| `Loggable` | Macro-generated logging support. |
| `Aemi` | Apple application umbrella: re-exports `AemiCore`, `AemiUI`, `InternedStrings`, and `Loggable`. |

Prefer a specific product when building a reusable library. Use the `Aemi`
umbrella when an Apple application needs that whole group.

### Runtime and parser building blocks

| Product | Provides |
| --- | --- |
| `AemiKernel` | Byte, integer, floating-point, and tape primitives. |
| `AemiKernels` | Swift access to the C byte-scanning and SIMD kernels. |
| `AemiUnicode` | Unicode primitives. |
| `AemiText` | Text algorithms built on the Unicode and byte primitives. |
| `AemiIO` | POSIX file and storage operations. |
| `AemiMetrics` | Process metrics. |
| `AemiRuntime` | Task/clock interfaces, resource pools, and blocking-work offloading. |
| `AemiFoundation` | Runtime umbrella for the kernel, text, IO, metrics, and concurrency products. |
| `AemiMacroSupport` | SwiftSyntax helpers for compiler plugins. Select this only in macro targets. |

`AemiFoundation` does not re-export UI, application helpers, test tools, or macro
compiler support. The manifest still resolves package-level dependencies such as
SwiftSyntax; selecting a small product controls what is built and linked.

### Tests

| Product | Use it for |
| --- | --- |
| `AemiTesting` | Testing application code that uses `AemiCore` task providers: clocks, gates, probes, semaphores, and spies. |
| `AemiTestKit` | Library and runtime tests: seeded data, fuzzing helpers, temporary files, allocation checks, clocks, and task coordination. |
| `AemiTestKitSeams` | The runtime task/clock interfaces re-exported for test support. |

Add testing products to test targets. `AemiTesting` and `AemiTestKit` currently
have distinct clock and task-provider APIs; select the kit that matches the
production module rather than importing both unqualified.

## Development

```sh
swift build
swift test
swift package --disable-sandbox lint
swift package --allow-writing-to-package-directory format
```

The `Format`, `Lint`, and `LintBuild` plugins are available to downstream packages.
Aemi's optional benchmark and documentation tooling uses `AEMI_DEV=1`; normal
consumers do not need that environment variable. `AEMI_FUZZ=1` enables the Linux
kernel fuzzer. These options use remote package dependencies.

## Consolidation

Aemi is the shared home for functionality previously maintained in ADFoundation,
AemiUtilities, AemiUI, and AemiSwift. The product names above are the dependency
surface for new consumers. Application-specific packages stay separate.

## License

[MIT](LICENSE).

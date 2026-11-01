# Aemi

Shared Swift building blocks for applications, libraries and developer tools: typed identifiers, concurrency utilities, byte and
text primitives, a Unicode and SIMD-accelerated kernel layer, macros, SwiftUI helpers, and deterministic test support.

Choose the products a target uses. A command-line parser does not need to link UI code, and an application does not need to ship
its test tools.

```swift
import AemiCore

enum User {}
enum Document {}

let userID = Identifier<User, String>("user-42")
let documentID = Identifier<Document, String>("document-42")
// Both store a String, but they are different types: passing one for the other does not compile.
```

## Add it

Swift 6.3 or later, in Swift 6 language mode. Apple platforms (iOS 18, macOS 15, tvOS 18, watchOS 11, visionOS 2); the kernel and
runtime products also support Linux.

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
            .product(name: "AemiTesting", package: "aemi"),
        ]
    ),
]
```

## What is in it

| For | Products |
| --- | --- |
| Applications | `AemiCore` (identifiers, task providers, throttling), `AemiUI` (SwiftUI helpers), `InternedStrings`, `Loggable`, and the `Aemi` umbrella |
| Bytes, text and Unicode | `AemiKernel`, `AemiKernels`, `AemiUnicode`, `AemiText`, [Base64](docs/base64.md) |
| Files and runtime | `AemiIO`, `AemiFileSystem`, `AemiInterner`, `AemiRuntime`, `AemiMetrics`, `AemiFoundation` |
| Languages and algorithms | `AemiLexers` (20 languages), `AemiDiff`, `AemiArgon2` |
| Macros | `AemiMacroSupport` |
| Tests | `AemiTesting`, `AemiTestKit`, `AemiTestKitSeams` ([testing](docs/testing.md)) |

[Products](docs/products.md) says what each one provides. Prefer a specific product in a reusable library, and the `Aemi` umbrella
only when an Apple application needs the whole group.

## Development

```sh
swift build
swift test
swift package --disable-sandbox lint
swift package --allow-writing-to-package-directory format
```

The `Format`, `Lint` and `LintBuild` plugins are available to downstream packages. How Aemi is built (decisions, measurements, the
working log) is in [`development/`](development/).

[MIT](LICENSE)

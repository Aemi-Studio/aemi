# Aemi

Shared Swift 6 building blocks for applications, libraries, and developer tools: typed identifiers, concurrency utilities, byte and text primitives, SIMD-accelerated C/Swift kernels, macros, SwiftUI helpers, and deterministic test support.

Link only the products each target needs. Non-UI products build on Apple platforms and Linux.

```swift
import AemiCore

enum User {}
enum Document {}

let userID = Identifier<User, String>("user-42")
let documentID = Identifier<Document, String>("document-42")
```

## Requirements

- Swift 6.3+ (Swift 6 language mode)
- iOS 18+, macOS 15+, tvOS 18+, watchOS 11+, visionOS 2+
- Linux for kernel, I/O, digest, runtime, and text products

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/Aemi-Studio/aemi.git", branch: "main")
]
```

Pin a specific `revision:` for reproducible builds.

## Products

| Group | Products |
| --- | --- |
| Application & UI | `Aemi`, `AemiCore`, `AemiUI`, `AemiFoundation` |
| Macros | `InternedStrings`, `Loggable`, `AemiMacroSupport` |
| Kernels & Bytes | `CAemiKernels`, `AemiKernels`, `AemiKernel`, `AemiUnicode`, `AemiText`, `AemiInterner`, `AemiLexers`, `AemiDiff` |
| Systems & Crypto | `AemiIO`, `AemiFileSystem`, `AemiProcess`, `AemiRuntime`, `AemiMetrics`, `AemiDigest`, `AemiArgon2` |
| Testing | `AemiTesting`, `AemiTestKit`, `AemiTestKitSeams`, `CAemiTestKitMalloc` |
| Build Plugins | `Format`, `Lint`, `LintBuild` |

## Documentation

- [Products](docs/products.md)
- [Base64](docs/base64.md)
- [Testing](docs/testing.md)
- [Architecture Decisions](docs/adr/)
- [Contributing](CONTRIBUTING.md)
- [Security](SECURITY.md)

## License

[MIT](LICENSE)

# Aemi

Shared Swift 6 building blocks for applications, libraries, and developer tools: typed identifiers, concurrency utilities, byte and text primitives, SIMD-accelerated C/Swift kernels, macros, SwiftUI helpers, and deterministic test support.

Link only the products each target needs. Every product builds on Apple platforms and Linux; the UI ones are empty on Linux.

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
- Linux for every product (`AemiUI` compiles empty there: it is SwiftUI)

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
## Privacy & Verification

- **Privacy:** `Aemi` runs 100% offline with zero network calls, zero telemetry, and zero personal data collection. See [`PRIVACY.md`](PRIVACY.md).
- **Security & Signatures:** Commits and release tags are GPG-signed (`1BF1 901A 8C67 2E9B C12E 1B31 9FE7 C7E8 522E E497`), and published release archives carry SHA-256 checksums and GitHub SLSA build provenance attestations (`gh attestation verify`). See [`SECURITY.md`](SECURITY.md).

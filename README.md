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
| `AemiIO` | POSIX file and storage operations, and file watching (FSEvents, kqueue). |
| `AemiMetrics` | Process metrics. |
| `AemiRuntime` | Task/clock interfaces, resource pools, and blocking-work offloading. |
| `AemiFoundation` | Runtime umbrella for the kernel, text, IO, metrics, and concurrency products. |
| `AemiMacroSupport` | SwiftSyntax helpers for compiler plugins. Select this only in macro targets. |

`AemiFoundation` does not re-export UI, application helpers, test tools, or macro
compiler support. The manifest still resolves package-level dependencies such as
SwiftSyntax; selecting a small product controls what is built and linked.

### Base64

`AemiKernel` encodes and decodes Base64 (RFC 4648) with the strictness each use needs. Pick a preset
of `Base64.Options`; every decode reports why it failed with a typed `Base64.DecodeError`, including
the byte offset.

| Preset | Use it for |
| --- | --- |
| `.strict` | **Signature-bearing or security-relevant text**, such as OpenPGP armor bodies, hashes, and anything compared byte for byte. Padding required, exactly one canonical text per byte string, no whitespace, no stray bytes. |
| `.urlSafe`, `.urlSafeNoPadding` | URL and filename tokens (RFC 4648 section 5): JWT segments, data URLs, query values. As strict as `.strict`. |
| `.mime` | Email bodies: 76-column lines, CRLF on encode, `LF` and `CR LF` skipped on decode, longer lines rejected. |
| `.pem` | PEM bodies: 64-column lines, LF on encode, line breaks skipped on decode. |
| `.lenient` | The historical behavior and the default of `Base64.decode(_:alphabet:)`: any `=` run, non-zero leftover bits. Existing callers keep it. |

```swift
import AemiKernel

// Strict, canonical armor: throws on any ambiguity.
let payload = try Base64.decode(armorBody, options: .strict)

// URL-safe, unpadded token.
let token = Base64.encodedString(digest, options: .urlSafeNoPadding)

// MIME / PEM bodies: wrapped lines are produced and accepted.
let mime = Base64.encodedString(attachment, options: .mime)
let der = try Base64.decode(pemBody, options: .pem)

// No allocation: decode into a buffer sized with the upper bound.
var buffer = [UInt8](repeating: 0, count: Base64.Options.strict.maximumDecodedLength(forEncodedCount: text.utf8.count))
let count = try buffer.withUnsafeMutableBufferPointer { out in
    try Base64.decode(text.utf8, into: out, options: .strict)
}
```

A preset is a value: change a field to tune it (`var options = Base64.Options.pem; options.maximumDecodedSize = 1 << 20`),
set `errorReporting = .uniform` to hide the failure cause from remote parties, or supply a validated
custom alphabet with `Base64.AlphabetTable(symbols:)`. Contiguous input (`Array`, `ArraySlice`, a
native `String`'s UTF-8, `Span`) takes a table-driven fast path.

### Tests

| Product | Use it for |
| --- | --- |
| `AemiTesting` | Testing application code that uses `AemiCore` task providers: clocks, gates, probes, semaphores, and spies. |
| `AemiTestKit` | Library and runtime tests: seeded data, fuzzing helpers, temporary files, allocation checks, clocks, and task coordination. |
| `AemiTestKitSeams` | The runtime task/clock interfaces re-exported for test support. |

Add testing products to test targets. `AemiTesting` and `AemiTestKit` have
distinct clock, probe and task-provider types (they conform to different
`TaskProvider` protocols); select the kit that matches the production module
rather than importing both unqualified.

The two kits follow the same rules, so a test reads the same against either:

| | `AemiTestKit` | `AemiTesting` |
| --- | --- | --- |
| Event probe | `AsyncEventProbe<Event>`: count waits and `wait(until:)` conditions, count-only form (`AsyncEventProbe()`), label and creation site, a timeout message that lists the 10 most recent events, clock-injectable timeouts; real-time default 30 s (a hang guard, so a long default costs time only when a test is stuck) | `CountProbe<Event>`: the same, including the 30 s default, except a wait returns nothing |
| Clock | `TestClock`: `sleeperCount`, `waitForSleepers(atLeast:)`, registration marks (`registrationMark()`, `waitForSleepers(_:after:)`), `advance(to:)`, `runToLastSleeper()`, `drain()`, untracked harness timers | `TestClock`: the same; sleepers resume in queued order rather than deadline order |
| Task provider spy | `TaskProviderSpy`: work and observation tracking, `cancelPendingWork()`, `cancelObservations()`, a `deinit` safety net, clock-injectable waits, a 30 s default timeout | `TaskProviderSpy`: the same, for `AemiCore`'s provider |
| Doubles and helpers | `ManualCompletion`, `deallocationProbe(of:)`, `waitForObservedState` | the same |
| Measurement | per-thread `mallocDelta` and `AllocationWindow`, `recordBenchmark`, the `.bench` tag | |

`AemiMetrics` adds `measureRate(units:rounds:_:)`, the best of several rounds by wall time and retired
instructions per unit. `deallocationProbe(of:)` needs the Objective-C runtime and `waitForObservedState` the
Observation module; both are compiled out elsewhere.

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

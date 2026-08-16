# Aemi

The kernel package of the Aemi ecosystem. One package, many small targets —
link exactly what you need. Consolidates what previously lived in
`AemiUtilities`, `AemiUI`, `AemiSwift`, `Presentable/AppProjection`, and now
absorbs the former `ADFoundation` (runtime kernel tiers + deterministic test
kit) and `ADBuildTools` (lint/format plugins, canonical configs, quality
scripts).

Platforms: iOS 18 / macOS 15 / watchOS 11 / tvOS 18 / visionOS 2.
Swift 6 language mode, strict concurrency; the pointer/POSIX kernel tiers
additionally adopt SE-0458 strict memory safety.

## Kernel tiers (absorbed from ADFoundation)

Foundation-free, zero-dependency runtime tiers, plus a test kit. Naming map
(old ADF name → new Aemi name):

| ADFoundation | Aemi |
|---|---|
| `ADFCore` | `AemiKernel` |
| `ADFKernels` / `CADFKernels` | `AemiKernels` / `CAemiKernels` |
| `ADFUnicode` | `AemiUnicode` |
| `ADFText` | `AemiText` |
| `ADFIO` | `AemiIO` |
| `ADFMetrics` | `AemiMetrics` |
| `ADConcurrency` | `AemiRuntime` |
| `ADFMacroSupport` | `AemiMacroSupport` |
| `ADTestKit` / `ADTestKitSeams` / `CADTestKitMalloc` | `AemiTestKit` / `AemiTestKitSeams` / `CAemiTestKitMalloc` |
| `ADFoundation` (umbrella) | `AemiFoundation` (umbrella) |
| `ADTesting` (umbrella) | `AemiTestKit` product (targets `AemiTestKit` + `AemiTestKitSeams`) |

- **`AemiFoundation`** — umbrella: one `import AemiFoundation` re-exports
  `AemiKernel`, `AemiKernels`, `AemiIO`, `AemiText`, `AemiUnicode`,
  `AemiMetrics`, and `AemiRuntime`. `AemiMacroSupport` is deliberately NOT
  re-exported (swift-syntax stays opt-in), and neither is `AemiCore`.
- **`AemiKernel`** — pointer-level byte/number primitives (strict memory safe).
- **`AemiKernels`** — runtime-dispatched SIMD byte kernels over the C target
  `CAemiKernels`; `AemiKernelsProbe` is the cross-arch differential checker.
- **`AemiUnicode` / `AemiText` / `AemiIO` / `AemiMetrics`** — Unicode kernel,
  text algorithms, POSIX IO, process self-metrics.
- **`AemiRuntime`** — zero-dep concurrency seams (`TaskProvider`/`Clock`) and
  pools (`ResourcePool`, `BlockingOffloadPool`). NOTE: distinct from
  `AemiCore`'s app-level `TaskProvider`/`TaskRole`; the two modules are never
  co-exported from a single umbrella.
- **`AemiTestKit`** (product) — the deterministic-testing kit (`AemiTestKit` +
  `AemiTestKitSeams` targets): Testing-backed asserts, `SeededRNG`, `Fuzz`,
  oracles, `TestClock`/`AsyncProbe`, gates, malloc counting via
  `CAemiTestKitMalloc`. Distinct from the app-level `AemiTesting` product
  (both define a `TestClock`; different modules, never co-exported).

## Dev tooling (`AEMI_DEV`) and plugins (absorbed from ADBuildTools)

Dev-only tooling is gated behind the `AEMI_DEV` environment variable so
consumers never resolve it. With `AEMI_DEV=1`:

- **Plugins** (in `Plugins/`): `Format` (`swift package format`), `Lint`
  (`swift package lint` — formatting gate + shipped-library discipline +
  SwiftLint metrics), `LintBuild` (prebuild `swift format lint --strict` on
  the kernel library targets).
- **Benchmarks**: the ordo-one suite (`AEMI_DEV=1 swift package benchmark`).
- Canonical `.swift-format` / `.swiftlint.yml` live at the repo root;
  `scripts/sync-config.sh`, `scripts/check-manifest-settings.sh`, and
  `scripts/check-tags.sh` plus `.github/workflows/swift-quality.yml` keep them
  from drifting.

`AEMI_FUZZ=1` additionally enables the Linux-only libFuzzer target
`AemiKernelsFuzz` (`-sanitize=fuzzer` is rejected by the Darwin SDK).

## App-level products

### `AemiCore`
General-purpose foundation, no UI dependency.

- **Typed identity** (from `Presentable/AppProjection` → `AppIdentity`):
  `Identifier<Owner, RawValue>` phantom-typed IDs, `AnyIdentifier` owner-erased
  keys for mixed collections.
- **Projections** (from `AppProjection`): `Projection`, read-side `Snapshot`,
  observable write-side `Mutable` (`@Observable`, buffered edits, `update()` /
  `revert()`), `Snapshot.updating(_:)`.
- **Concurrency injection** (from `AemiSwift` → `AemiConcurrency`):
  `TaskProvider`, `TaskRole`, `DefaultTaskProvider`.
- **Task utilities** (from `AemiUtilities`): `Throttler`, `DependantTask`.
- **Helpers** (from `AemiUtilities` + canonical versions of app-duplicated
  helpers): `Collection[safe:]`, `Collection[guard:]`,
  `MutableCollection[guard:]`, `Comparable.clamped(to:)`,
  `Publisher.stream` (Combine → `AsyncStream`), `Platform` detection.

### `AemiUI`
SwiftUI helpers. Depends on `AemiCore`.

- **From `AemiUtilities` (SwiftUI parts)**: `.if` conditional modifiers, size
  updater (`.update(_:)`), visibility tracker (`.track(visibility:...)`, iOS),
  bounds tracker (`.track(bounds:)`), visual debug overlay (`.debug()`),
  platform-specific modifier (`.for(_:)`), keyboard-height publishers and
  `.update(keyboardSize:)` (iOS), `EdgeInsets.safeAreaInsets` (iOS),
  `UIApplication.currentScene/currentScreen` (iOS).
- **From the old `AemiUI` package**: autosizing popover and sheet modifiers,
  checkbox styles (`BooleanCheckbox`, `NativeToggleCheckboxStyle`,
  `ObservingCheckbox`), `FixedSize`.
- **New**: `Color(hex:)` canonical implementation; haptics vocabulary modeled
  on Glassware's `GlassHaptics` — `HapticEvent`, `HapticsConfiguration`,
  `.haptics(_:)` environment modifier, `.haptic(_:trigger:)` sensory-feedback
  emitter, and a pre-warmed `HapticEngine` (iOS) for imperative call sites.

### `AemiTesting`
Deterministic async test infrastructure (from `AemiSwift` → `AemiTesting`):
`TestClock`, `TaskGate`, `CountProbe`, `AsyncProbe`, `AsyncSemaphore`,
`TaskProviderSpy`. Requires iOS 18 / macOS 15 at runtime (`Mutex` from the
Synchronization framework); annotated with `@available` accordingly.

### `AemiTCA` (separate package: `aemi-tca`)
Composable Architecture helpers live in the sibling `aemi-tca` package,
because its `Dependence` dependency requires the iOS 26 platform
generation and would otherwise raise this package's floor. It depends on
`aemi` (AemiCore), `Aemi-Studio/dependence` (DI surface, re-exported),
and `swift-composable-architecture` (`Effect.debounce` helper).

### `Aemi` (umbrella)
Re-exports `AemiCore`, `AemiUI`, `InternedStrings`, `Loggable`.

### `Loggable` / `InternedStrings`
Pre-existing macro-backed products, unchanged. External consumers
(AemiSDR, AlertKit) depend on them.

## Deliberately not migrated

- `Presentable`'s `AppNetworking`, `LoadState` (superseded by `AemiTCA`'s),
  and DTOs — app-specific, out of scope for the shared foundation.
- Glassware's haptics were re-modeled, not copied.

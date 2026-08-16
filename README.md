# Aemi

Unified shared-foundation package for all Aemi Studio apps. One package, seven
products, consolidating what previously lived in `AemiUtilities`, `AemiUI`,
`AemiSwift`, and `Presentable/AppProjection`.

Platforms: iOS 17 / macOS 14 / watchOS 10 / tvOS 17 / visionOS 1.
Swift 6.2 language mode, strict concurrency, strict memory safety.

## Products

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

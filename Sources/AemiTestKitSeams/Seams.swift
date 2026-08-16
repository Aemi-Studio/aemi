// `AemiTestKitSeams` is now a stable re-export name for the `AemiRuntime` leaf.
//
// The shipped-safe production seams (`TaskProvider`/`LiveTaskProvider`, the `Clock`/`now`
// injection points `EpochSecondsProvider`/`MonotonicNanosecondsProvider`/`LiveClock`) and the
// `ResourcePool` pooling primitive moved into the zero-dependency `AemiRuntime` package, so a
// production library (ADJSON) can depend on `AemiRuntime` instead of a package named
// "TestKit". This module re-exports them unchanged, so every existing `import AemiTestKitSeams`
// call site — `TaskProviderSpy`, the AD-family seam consumers — keeps compiling verbatim.
@_exported import AemiRuntime

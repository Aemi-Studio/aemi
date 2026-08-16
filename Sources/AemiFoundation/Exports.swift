// The umbrella `AemiFoundation` module re-exports every Foundation-free, zero-dependency runtime tier,
// so a single `import AemiFoundation` sees the byte/number kernel, the Unicode kernel, the text
// algorithms, the POSIX storage primitives, and the process self-metrics as one flat public API —
// callers no longer cherry-pick `import AemiKernel` + `import AemiUnicode` + … tier by tier.
//
// `AemiMacroSupport` is deliberately NOT re-exported: it links swift-syntax and is a compile-time
// helper that macro plugins import directly. Keeping it out of the umbrella means a plain
// `import AemiFoundation` never drags swift-syntax into a consumer's resolution or link graph.
@_exported import AemiIO
@_exported import AemiKernel
@_exported import AemiMetrics
@_exported import AemiRuntime
@_exported import AemiText
@_exported import AemiUnicode

# Products

Select products per target. `AemiFoundation` does not re-export UI, application helpers, test tools or macro support.

## Applications

| Product | Provides |
| --- | --- |
| `AemiCore` | Typed identifiers, projections, task providers, throttling, and collection helpers. |
| `AemiUI` | SwiftUI presentation, layout, visibility, and haptics helpers. Depends on `AemiCore`. |
| `InternedStrings` | Attached and expression macros for string obfuscation. |
| `Loggable` | Macro-generated logging support. |
| `Aemi` | Apple application umbrella: re-exports `AemiCore`, `AemiUI`, `InternedStrings`, and `Loggable`. |

Prefer a specific product when building a reusable library. Use the `Aemi`
umbrella when an Apple application needs that whole group.

## Runtime and parser building blocks

| Product | Provides |
| --- | --- |
| `AemiKernel` | Byte, integer, floating-point, and tape primitives; strict UTF-8 reading, checked byte views, byte bitmaps, sparse sets; for parsers: keyed hashing (`KeyedHash`, `HashIndex`), safe ranged scans with a SWAR front (`ByteScan`), decimal literals (`DecimalScanner`) and RFC 3339 dates (ADR 0031). |
| `AemiKernels` | Swift access to the C byte-scanning and SIMD kernels: single bytes, sets, pairs and pair sets (Teddy), CRC-32C, buffer bit counts and UTF-16LE ASCII narrowing. |
| `AemiUnicode` | Unicode primitives: categories, scripts, binary properties and case folding (Unicode 17), scalar sets. |
| `AemiText` | Text algorithms built on the Unicode and byte primitives. |
| `AemiIO` | POSIX file and storage operations, and file watching (FSEvents, kqueue). |
| `AemiFileSystem` | A parallel directory walker on `readdir` and `d_type`: no stat per regular file, directories opened by root-relative path with no link followed, policies for names, links, pruning and limits, a sorted result or batches while it runs. |
| `AemiInterner` | UTF-8 keys as dense `UInt32` symbols without making a `String`: a chunked arena, an open-addressing table hashed with wyhash, a frozen form for readers on any thread, a parallel merge whose symbols equal sequential interning, and a compact serialised form. |
| `AemiMetrics` | Process metrics. |
| `AemiLexers` | Syntax lexers for 20 languages over borrowed UTF-8: a whole text, or a line at a time from each line's entry state, with the roles and line tokens a highlighter needs. Standard library only. |
| `AemiDiff` | Text diffs: Myers and histogram line diffs over interned lines, intraline emphasis, moved blocks, hunk layout, unified patches and gutter change marks. Standard library only. |
| `AemiArgon2` | Argon2d, Argon2i and Argon2id (RFC 9106) and BLAKE2b (RFC 7693), for a key from a password; kernels in C (`CAemiArgon2`): NEON, NEON with SHA3, SSSE3, AVX2, lanes on threads, data-independent timing on Apple silicon, a constant-time comparison and wipes. |
| `CAemiCPU` | What this CPU can do, asked once: the feature set every C kernel dispatches on, and a data-independent timing scope for code handling secrets. |
| `AemiRuntime` | Task/clock interfaces, resource and scratch pools, and blocking-work offloading. |
| `AemiFoundation` | Runtime umbrella for the kernel, text, IO, metrics, and concurrency products. |
| `AemiMacroSupport` | SwiftSyntax helpers for compiler plugins. Select this only in macro targets. |

`AemiFoundation` does not re-export UI, application helpers, test tools, or macro
compiler support. The manifest still resolves package-level dependencies such as
SwiftSyntax; selecting a small product controls what is built and linked.


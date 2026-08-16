# ``AemiFoundation``

Shared, modular foundations for the g-cqd engines — ADJSON, ADSQL, URLBuilder, and apple-docs.

## Overview

AemiFoundation is the dependency root beneath the g-cqd engines. It holds only **domain-neutral**
primitives, split into tiers by dependency footprint so each consumer links exactly what it needs:

- ``AemiKernel`` — byte buffers and readers, varint and little/big-endian codecs, overflow-checked
  arithmetic, ASCII classification, RFC 3629 UTF-8 validation, percent-coding, non-cryptographic
  hashing. Zero transitive dependencies.
- ``AemiUnicode`` — canonical decomposition, case-folding, and Unicode property sets.
- ``AemiText`` — bounded edit distance and tokenizer kernels.
- ``AemiIO`` — POSIX file channel, memory mapping, and cross-process atomics.
- ``AemiMacroSupport`` — swift-syntax helpers shared by macro compiler plugins (diagnostics,
  source-literal escaping, identifier backticking). The only tier that links swift-syntax.

`import AemiFoundation` re-exports every zero-dependency runtime tier — ``AemiKernel``, ``AemiUnicode``,
``AemiText``, and ``AemiIO``. ``AemiMacroSupport`` is imported directly by macro plugins (it links
swift-syntax, so the umbrella leaves it out). Everything floors at macOS 15 / iOS 18 / tvOS 18 /
watchOS 11 / visionOS 2 and is Foundation-free.

## Topics

### Tiers

- ``AemiKernel``
- ``AemiUnicode``
- ``AemiText``
- ``AemiIO``
- ``AemiMacroSupport``

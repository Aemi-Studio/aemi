# ``AemiMacroSupport``

swift-syntax helpers shared by macro compiler plugins: a uniform diagnostic, Swift source-literal
escaping, and identifier backticking.

## Overview

`AemiMacroSupport` is the one AemiFoundation tier that links swift-syntax. It is imported directly by the
macro compiler plugins of the g-cqd engines (ADJSON, ADSQL, URLBuilder) and is deliberately excluded
from the ``AemiFoundation`` umbrella, so a plain `import AemiFoundation` never drags swift-syntax into a
consumer's resolution or link graph.

It provides a shared ``SimpleDiagnostic`` plus a ``macroDiagnostic(_:domain:id:_:severity:)`` builder
that namespaces each plugin's identifier space, and two pure `String` → `String` helpers —
``escapedIdentifier(_:)`` and ``swiftStringLiteral(_:)`` — so each plugin stops re-rolling identifier
backticking and string-literal escaping when emitting Swift source from an expansion.

## Topics

### Diagnostics

- ``SimpleDiagnostic``
- ``macroDiagnostic(_:domain:id:_:severity:)``

### Emitting Swift source

- ``escapedIdentifier(_:)``
- ``swiftStringLiteral(_:)``
- ``swiftKeywords``

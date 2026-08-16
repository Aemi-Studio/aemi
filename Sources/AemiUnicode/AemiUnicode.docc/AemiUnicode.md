# ``AemiUnicode``

The generic Unicode kernel: canonical decomposition, case-folding, and property sets.

## Overview

`AemiUnicode` holds the Unicode primitives that are domain-neutral — NFD decomposition, case-folding,
and binary-searchable scalar property sets — so the SQL full-text tokenizers (`Unicode61`, `Porter`,
`Trigram`) and the document content/embedding pipelines stop re-deriving them. Domain-specific
tokenizers stay in their owning packages and build on this kernel. Stdlib-only, Foundation-free.

## Topics

### Canonical decomposition

- ``NFD``

### Case folding

- ``CaseFolding``

### Scalar property sets

- ``UnicodeSets``

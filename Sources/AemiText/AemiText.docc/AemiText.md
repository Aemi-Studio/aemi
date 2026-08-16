# ``AemiText``

Generic text algorithms: bounded edit distance and tokenizer kernels.

## Overview

`AemiText` holds the domain-neutral text algorithms that were duplicated between fuzzy search and
full-text indexing — early-exit Levenshtein edit distance and the substring/window tokenizer
kernels. Stdlib-only, iterative, Foundation-free. The tokenizer kernels return index ranges rather
than copied subsequences, so the caller picks the element granularity and slices on demand.

## Topics

### Bounded edit distance

- ``AemiText/editDistance(_:_:maxDistance:)``
- ``AemiText/editDistanceFull(_:_:maxDistance:)``
- ``AemiText/editDistanceBanded(_:_:maxDistance:)``

### Tokenizer kernels

- ``AemiText/windows(_:size:)``
- ``AemiText/split(_:omittingEmptySubsequences:where:)``

---
status: accepted
date: 2026-10-30
---

# 0021 — Every kernel is tested against inaccessible pages; `GuardedBytes` in AemiTestKit

## Context

The C kernels read in 16- and 64-byte blocks and finish with overlapping loads, word steps and masked tails: the places a read
one byte past the input lands. Comparing results cannot see such a read, since the stray byte is usually mapped and ignored.
The sanitized C checks (`scripts/*-check.sh`) see it under ASan, outside `swift test`. MacFS tested its own kernels with
inputs ending at a `PROT_NONE` page; that test is general.

## Decision

`GuardedBytes.with(_:against:_:)` in AemiTestKit: the bytes flush against an inaccessible page at the end or at the start, so a
read beyond either edge crashes. `AemiKernelsGuardPageTests` runs every public kernel so placed, at every length to 130 and
around 256 and 4096, against both edges, comparing `.fastest` with `.scalar`.

## Evidence

- Red first: `GuardedBytes` as a heap copy failed both exit tests (a read one past the end, one before the start, did not stop).
- Three planted overreads each crash the kernel suite (SIGBUS): the UTF-16 word step taken with three units left, the CRC's last
  byte read one further, the scalar bit count taking a word with seven bytes left.
- The suite runs in about 25 ms.

## Consequences

A new kernel gets a line in that suite. The guard needs `mmap` and `mprotect`; on Linux it uses Glibc's, not run here.

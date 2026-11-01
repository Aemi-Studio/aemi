---
status: accepted
date: 2026-11-01
---

# 0023 — Atelier promotes its diff as AemiDiff

## Context

Atelier's `AtelierDiff` diffs two texts: Myers and histogram line diffs over interned lines, the refiners that move a script's
edges where a reader expects them, line pairing, intraline emphasis, moved blocks, row alignment, hunk layout, unified patches and
the change marks an editor's gutter shows. ask needs the same diff to show a file edit as removed and added lines (ask roadmap
0152), and ask may not depend on Atelier. As for the lexers (0022), the owner chose a module of aemi over a repository of its own
(2026-11-01). GitDiffViewer's drawing (`DiffRendering`, `DiffTextKit`) is AppKit and TextKit and stays in the app.

## Decision

- **`AemiDiff`, a product of its own**, over `AemiKernel`, `AemiText` and `AemiLexers` (for `Language`, which the syntax tier of the
  intraline diff names). Standard library only: `memcmp` became `ByteCompare.equal`, and a git header's paths are trimmed and
  searched with the standard library.
- **`LineSource` and `TextLines` move to `AemiText`** from TerminalKitText, where they arrived from Atelier: the line shape a diff
  reads, and a string's lines as the diff cuts them, found with `AemiKernels.firstIndexOfByte` (libc's `memchr`, as before).
  TerminalKitText keeps its rope, which conforms to the protocol here, and names both types for its clients.
- **From the 26 releases on**, as `AemiLexers`: lines are lent as spans, so every declaration carries that availability.
- **The code is otherwise unchanged**, file for file. Its 71 tests moved with it, but one: that a rope is a diff source, which
  needs TerminalKit and moved to KittyCode's tests of its rope's line source. The two opt-in benchmarks read their corpus from
  Atelier's history and take its clone from `AEMI_DIFF_BENCH_REPO`.

## Consequences

- Atelier deletes `AtelierDiff` and imports `AemiDiff` once its aemi pin moves past this change; TerminalKit names `AemiText`'s
  line types once its pin does.
- A diff of strings is one call, `DiffModel(oldText:newText:)`, or `LineDiff.diffLines` for the edit script alone.

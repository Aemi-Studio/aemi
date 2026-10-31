---
status: accepted
date: 2026-10-31
---

# 0022 — Atelier promotes its lexers as AemiLexers

## Context

Atelier's `AtelierLexers` scans 20 languages over borrowed UTF-8: a whole text, or one line at a time from the state the line before
it ended in. ask needs the same scanners to colour code blocks in its terminal (ask roadmap 0152, 0087), and ask may not depend on
Atelier. The owner chose a module of aemi over a repository of its own (2026-10-31).

## Decision

- **`AemiLexers`, a product of its own**, not in the `AemiFoundation` umbrella. Standard library only: no Foundation, no TerminalKit.
- **What moved** (Atelier `1e4ae04`): the four scanners and their language table, `SyntaxHighlighter`, `LineLexer` with
  `LexicalLineLexer`, `LexState` and `LexStates`, and the model types they need: `Language`, `HighlightRole` with its hierarchy,
  `HighlightModifierSet`, `LineToken`, `UTF16Offsets`, and the `TokenKind` to role mapping. Atelier keeps its tier engine,
  `ProgressiveHighlighting` and the rest of its syntax model, over this module.
- **No generic entry point in the public API.** The scanners build their tokens in place through an internal `ScannerToken`
  protocol. Made public, a client's own token type went through an unspecialized generic and the scan ran about 3 times slower
  (Swift at 200 MB/s against 620). Clients take `Token` or `LineToken` and map them to their own types.
- **From the 26 releases on.** The scanners borrow their tables and their callers' arrays as spans, which the standard library
  offers from those releases, so `SyntaxHighlighter` and `LexicalLineLexer` carry that availability; the value types do not.

## Evidence

- The corpus checksums pinned in Atelier pass unchanged, for byte and UTF-16 offsets, in all 20 languages; so do the line-scan
  equivalence, prefix, parity and allocation tests (36 tests).
- Throughput, release build, the 2 MB generated corpus per language, Apple M3: from 359 to 674 MB/s in Atelier, from 356 to 698
  MB/s here, with the same token checksums; the median language runs at 0.96 of its Atelier time.

## Consequences

- Atelier deletes its copies and consumes `AemiLexers` once its aemi pin moves past this change. Its engine then maps `Token` to its
  `HighlightToken`, one more array a scan; to be measured there.
- The line tests no longer use TerminalKitText's `TextLines`: they cut lines themselves.

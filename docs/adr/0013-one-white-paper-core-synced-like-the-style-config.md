---
status: proposed
date: 2026-10-20
---

# 0013 — One white-paper core, kept in Aemi and synced like the style configuration

## Context

The ecosystem's principles exist as copies: `ask/docs/WHITE-PAPER.md` and `TerminalKit/docs/WHITE-PAPER.md`,
and as of 2026-10-20 a third adapted copy in AemiSDR. TerminalKit's copy records that it had already
drifted once ("The two white papers must not diverge, and one had drifted"), on a runtime principle that
a probe had refuted in one copy and not the other. A principle corrected in one place and not another is
worse than none: each repository can cite the version that suits it.

Aemi already solves this shape for `.swift-format` and `.swiftlint.yml`: one canonical file here,
`scripts/sync-config.sh` to copy it, and a drift check in `swift-quality.yml` that fails a consumer whose
copy differs (TerminalKit ADR-0003 probed that the check fails).

## Decision (proposed)

- Aemi holds `docs/WHITE-PAPER-CORE.md`: the parts that bind every package — runtime principles, the
  evidence rule, red TDD, performance doctrine, strictness, documentation law, commit discipline, bans.
- Each package's `docs/WHITE-PAPER.md` is the core, verbatim between two markers, followed by its own
  doctrine sections (TerminalKit: terminal verification; `ask`: terminal and sandbox; AemiSDR: private API,
  GPU and capture; HTTP: RFC conformance; AemiJSON: fuzzing and the NIO legs; the analyzers: the frozen
  1.x output contract and false-positive measurement before a rule gates).
- Platform floors differ, so the core states a principle and the package states its floor's consequence
  (AemiSDR at iOS 18: `Mutex` and `Atomic` compile; `Span` and `InlineArray` do not — probed).
- `sync-config.sh` updates the marked region; the shared gate fails when it differs from the canonical core.
- `DocumentationLayout` and its tests are promoted here (they exist three times already: `ask`,
  TerminalKit, AemiSDR), so the documentation law is one implementation.

## Consequences

- Changing a principle becomes one reviewed change in Aemi that every package picks up when it moves its
  pin — the same cadence as the style configuration.
- The first sync is a reconciliation. Diffing the two runtime-principle sections today: `ask` has
  "Every change that can affect performance is benchmarked" where TerminalKit has the narrower "Every
  claim is measured", and only `ask` has "Reliable by default, and never silent"; the rest differ in
  wording. That reconciliation is its own commit, with the diff in the message.

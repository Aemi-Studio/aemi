---
status: accepted
date: 2026-11-04
---

# 0030 — Consumers pin one aemi revision, and aemi's history is not rewritten

## Context

Every package of the family depends on aemi by `revision:`, so that a push to aemi cannot change the C kernels and the unsafe
code a consumer builds (ADR 0025, 0026). On 2026-11-04 aemi's history was rewritten once, to take a host name out of an ADR. A
rewrite changes every hash after the first changed commit, and here it also dropped the commit signatures, so all 186 hashes
changed. Every consumer's pin then named a commit that no longer existed upstream, and the consumers of consumers (AemiJSON,
AemiProtobuf, analyzerkit, the analyzers) had to be repinned in dependency order and released again.

## Decision

- aemi's `main` is append-only. A mistake in a record is corrected by a new commit; a rewrite needs the owner's explicit say and a
  list of every pin that names a rewritten commit (`git grep` over the family for the old hashes, in `Package.swift`,
  `Package.resolved`, benchmark packages, scripts that read a commit, and ADRs that cite one).
- One aemi revision per dependency graph: SwiftPM refuses two revision requirements for one package, so AemiRegex, AemiJSON,
  AemiProtobuf, AemiMarkdown, TerminalKit, analyzerkit, ask and the analyzers all name the same hash, and a repin moves them
  together, leaves first.
- Scripts that rebuild an older tree from git name it by a hash that is checked in CI (`Scripts/bench-c-kernels.sh --check`).
  They are the first thing a rewrite breaks.

## Consequences

- Under ThreadSanitizer on Linux, `ByteBufferPool` (a `Synchronization.Mutex`, which that runtime does not model) is reported as
  an access race by a command-line run that encodes JSON on several threads, and the run exits 66. The pool is correct; consumers
  whose tests run their own executable under the sanitizer keep the executable's exit code (fcheck does).

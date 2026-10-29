---
status: accepted
date: 2026-10-29
---

# 0017 — A parallel directory walker on `readdir`, opening by root-relative path

## Context

analyzerkit's ADR-0013 places a parallel directory walker in Aemi, for its five analyzers and for ask and KittyCode, and left
two questions to measure: `getattrlistbulk` against `readdir` with `d_type`, and the descriptor budget. Measured in diary
2026-10-29-02: `getattrlistbulk` reads the inode of every entry, so it is barely faster warm, slower cold, and 150 times
slower on a directory larger than the vnode cache; `readdir` with `d_type` reads only directory records. The work queue of a
parallel walk of maintastic peaks at 440 directories, more than launchd's default soft limit of 256 descriptors.

## Decision

1. `AemiFileSystem`, a new target beside `AemiIO`, walks a tree with `readdir` and `d_type` (on Linux the same through
   `getdents64`). An entry's type comes from its directory record; `fstatat` runs only for `DT_UNKNOWN`, a link the policy
   resolves, or a directory whose identity the visited set needs. Never once per regular file.
2. It opens the root once and every directory relative to it: `openat(root, relativePath, O_DIRECTORY | O_NOFOLLOW_ANY)` on
   Darwin, so a directory replaced by a link anywhere on its path during the walk is refused, not followed. The queue holds
   relative paths, not descriptors: one descriptor per worker, plus the root, whatever the tree's width. On Linux,
   `openat2` with `RESOLVE_NO_SYMLINKS | RESOLVE_BENEATH`, else component by component with `O_NOFOLLOW`.
3. Workers: a bounded pool, default `min(4, active processors)`, over one shared queue; each worker lists one directory
   completely. Four was the knee measured; eight was slower.
4. Policies are inputs, as analyzerkit's ADR-0013 lists them: skipped names, hidden entries, links (never, or within the
   root with a device-and-inode visited set), a name predicate, a path predicate asked before a directory is entered (so a
   path filter prunes), a limit, cancellation. Unreadable directories are reported with their error.
5. Results are deterministic: sorted by path at the end, and available as an `AsyncSequence` of batches while the walk runs.

## Consequences

- analyzerkit's `SourceDiscovery` becomes a policy over the walker (its roadmap 0007); its per-entry `attributesOfItem` goes.
- `getattrlistbulk` is not used. A consumer that needs sizes or dates asks for them on the files it keeps.
- Linux behaviour is designed here and tested by the Linux CI, not measured.

---
status: accepted
date: 2026-10-29
---

# 0016 — File watching in AemiIO: two kernel backends behind one protocol

## Context

Two consumers had written their own watchers. Atelier's `AtelierFileTree.FileWatcher` (FSEvents, an actor, trees and files followed
by path, history replayed across restarts, suppression of the app's own writes, a rescan when the consumer falls behind) serves
KittyCode's workspace and configuration file and GitDiffViewer's freshness. ask's `DirectoryWatch` and `BinaryWatcher` (kqueue on a
directory, a 64 KiB pthread) watch for a rebuilt executable and wait for files to appear, and ask now needs to watch its
configuration files, whose directories may not exist yet (`<project>/.ask/config.json`). The owner asked for both kinds to become one
reusable, composable surface in AemiIO, used by both apps.

## Decision

- **One vocabulary.** `FileWatchEvent` (`fileChanged(path as registered)`, `directoryChanged(canonical path)`), the `FileWatching`
  protocol (`events`, `watchDirectory`, `watchFile`, `unwatchFile`, `suppressNotifications`, `stop`; promoted from KittyCode),
  `CanonicalPath` (`realpath` as far as the path exists, keys for a symlinked file) and `FileIdentity` (device, inode, size, time; from
  ask's `BinaryIdentity`, without Foundation). An event is a reason to look again, never a description.
- **Two backends, chosen by the consumer.**
  - `FileWatcher` (FSEvents, macOS): Atelier's watcher, moved whole. Trees, any number of paths on one stream, entry-level directory
    events, history replay, exclusions; FSEvents' coalescing latency (0.1 s by default).
  - `KqueueWatcher` (kqueue, every Apple platform): new, on ask's primitives. One directory level; a file followed by path (its
    directory and the file itself held open, so atomic saves and writes in place are both seen); a file whose directories are missing
    is anchored on the nearest existing ancestor and moves down as they appear. No delay; one descriptor per path, so for a handful of
    paths.
  - `DirectoryWatch`: the blocking one-directory wait, public, for one-off waits on a caller's thread.
- **Foundation-free, as AemiIO is.** The FSEvents port takes C-string paths instead of `UseCFTypes`, builds its `CFArray` with
  `CFArrayCreate`, and reports refusals through an `onFailure` closure instead of `os.Logger`. Strict memory safety marks every pointer
  site. The watching files compile only on Darwin (`canImport(Darwin)`; FSEvents under `os(macOS)`); Linux gets nothing yet, and
  inotify is the natural third backend.

## Measured

Release builds, two directories watched, one atomic save, three identical runs each (ask's measurement, 2026-10-29): a Foundation program
idles at 5,840 KiB and one thread; FSEvents adds 176 KiB and a queue thread and reported the save once; kqueue adds 64 KiB and one thread
and reported it twice.

## Consequences

- Tests: Atelier's suite moved with its watcher (stream restarts, exclusions, overflow rescan, the tmp symlink, the table and path
  units); new ones for `KqueueWatcher` (writes in place, three atomic saves, missing directories created later, a directory removed and
  made again, one level only, suppression, unwatch, the thread closing its queue on stop and on release), `DirectoryWatch` and
  `FileIdentity`. Writing them found two bugs before release: a wake trigger that replaced the event's tag, so a wake read as a change,
  and a directory made between choosing an anchor and registering it going unseen.
- Not tested: `KqueueWatcher`'s overflow rescan (kqueue coalesces a directory's events, so a burst does not fill the buffer the way it
  does FSEvents'), and the Swift 6.3 floor (only 6.4.0 is installed here; CI runs 6.3.3).
- Atelier's `AtelierFileTree` and ask's `AskTools` drop their copies and use these.

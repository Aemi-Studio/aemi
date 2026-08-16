# Scratch files & directories

Get a private, owner-only scratch directory or database path that cleans up after itself —
including the sidecar files a storage engine drops next to it.

## The problem

Storage tests need a real path on disk: a database file, its `-wal` / `-shm` / `-lock`
siblings, sometimes a whole tree. The naive approaches leak or race. Building a path in the
shared temp directory and hoping the name is unique invites collisions between parallel
tests and leaves debris when an assertion fails before cleanup. Hand-rolled recursive
deletes that walk the directory stream and read each entry's `d_name` through a raw pointer
are fragile — AddressSanitizer flags the read when a record sits at the end of the stream's
buffer — and a delete that only `unlink`s top-level entries silently *leaks* any
subdirectory, because `unlink` can't remove a directory and the trailing `rmdir` then fails.

## The design

``TemporaryDirectory`` creates its directory with `mkdtemp` — an atomic, race-free syscall
that makes a uniquely-named **`0700`** (owner-only) directory in a single step, with no
time-of-check/time-of-use window. Paths are joined through swift-system's `FilePath` for
correct separator handling, and teardown is one safe, recursive `FileManager.removeItem` —
no raw directory-stream walk, no leaked subdirectory.

`withTemporaryFilePath(prefix:extension:_:)` vends a scratch file path *inside a fresh
private ``TemporaryDirectory``* and removes the **entire** directory afterward. Because the
file lives in its own directory, that single removal also clears every `-wal` / `-shm` /
`-lock` engine sibling the caller drops beside it — with no hard-coded suffix list to keep
in sync with the storage engine.

### Why it matters

The atomic `0700` creation is a genuine safety property, not ceremony: it closes the symlink
and name-collision attacks that a "generate a name, then create" sequence opens, and it
keeps scratch data unreadable by other users on a shared CI host. Replacing the raw
`d_name` walk with `FileManager` removal makes the helper ASan-clean and fixes a real
subdirectory leak — the kind of latent bug this kit exists to retire family-wide.

## Using it

Scoped directory that always cleans up, even on a thrown assertion:

```swift
try TemporaryDirectory.withTemporaryDirectory { dir in
    let path = dir.file("fixtures.json")
    try sample.write(toFile: path, atomically: true, encoding: .utf8)
    #expect(Loader.load(path).count == 3)
}   // directory and everything in it is removed here
```

A database path whose engine siblings are swept automatically:

```swift
try withTemporaryFilePath(extension: "db") { path in
    let db = try Database(path: path)            // creates path, path-wal, path-shm
    try db.execute("CREATE TABLE t(x)")
    #expect(try db.tableNames() == ["t"])
}   // path and every sidecar removed with the private directory
```

### When to use it

- Use ``TemporaryDirectory`` when you need a private tree, and `TemporaryDirectory/file(_:)`
  or `TemporaryDirectory/filePath(_:)` to address entries inside it.
- Use `withTemporaryFilePath(prefix:extension:_:)` for database/engine tests so the `-wal` /
  `-shm` / `-lock` siblings are cleaned without naming them.
- Prefer the scoped `withTemporaryDirectory(prefix:_:)` / `withTemporaryFilePath` forms over
  a bare ``TemporaryDirectory`` so cleanup runs even when the body throws.

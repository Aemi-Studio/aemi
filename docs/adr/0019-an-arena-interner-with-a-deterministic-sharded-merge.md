---
status: accepted
date: 2026-10-29
---

# 0019 — An arena interner, hashed with wyhash, merged deterministically by shard

## Context

analyzerkit's ADR-0012 asks Aemi for a real interner (`InternedStrings` is compile-time obfuscation) and left three
questions to measure: the gain over `[String: UInt32]` for long and short keys, the hash, and a parallel merge against a
lock-striped table. Measured in diary 2026-10-29-03 on maintastic's two workloads: 661,234 USR occurrences (120,256
distinct, 120 bytes on average; deadwood) and 1,123,010 token occurrences (30,209 distinct, 21 bytes; dolly).

| one thread | USRs | tokens |
|---|---|---|
| `[String: UInt32]`, a `String` made from the bytes | 102 ms | 37.5 ms |
| `[String: UInt32]`, the `String` already made | 77 ms | 26.4 ms |
| arena, SipHash-1-3 | 48.1 ms | 25.0 ms |
| arena, XXH64 | 22.8 ms | 16.8 ms |
| arena, wyhash | 17.2 ms | 14.7 ms |
| memory per distinct key, dictionary and symbol list | 244 B | 107 B |
| memory per distinct key, arena | 171 B | 72 B |

With four workers, per-worker tables merged by hash shard took 8.6 and 7.7 ms and gave exactly the sequential symbols; a
table split in 64 lock-striped shards took 18.8 and 31.6 ms, got slower with more workers, and numbers keys in the order
threads happen to reach them.

## Decision

1. `AemiKernel` gains `WyHash` (wyhash final 4.2, default secret, an optional seed), checked against the reference
   `wyhash.h`. It is not a defence against chosen keys; the analyzers hash their own users' sources. `XXH64` stays for
   checksums.
2. `AemiInterner`, a new target depending on `AemiKernel` only. Key bytes are copied into 64 KiB chunks that never move
   (a longer key gets a chunk of its own). The table is open addressing over 64-bit slots, the hash's top 32 bits beside
   symbol + 1, so bytes are compared only when 32 bits of hash agree; it doubles past three quarters full, rehashing from
   each symbol's stored hash. A `Symbol` is a `UInt32`, numbered from 0 in first-occurrence order.
3. Interning takes UTF-8 bytes (`UnsafeRawBufferPointer`, a `String` or `Substring` through its contiguous UTF-8) and never
   makes a `String`; a symbol resolves to its bytes, borrowed for as long as the interner lives, or to a `String` on
   request.
4. Three forms:
   - `Interner`: one owner, mutable; one per task.
   - `FrozenInterner`: immutable, `Sendable`, lookups and resolution from any thread.
   - `Interner.merge(_:workers:)`: per-task interners, given in input order, merged into a `FrozenInterner` plus one table
     per input mapping its local symbols to the merged ones. Each shard of the hash (64, by six bits of it) is merged by
     one worker, owners chosen in input order; symbols are then numbered by (input, local symbol), which is
     first-occurrence order over the concatenated input: the symbols one interner reading everything in order would
     give, whatever the number of workers. The inputs' chunks are kept, not copied. No lock-striped table.
5. Serialisation: symbol count, then each key's length as a LEB128 varint, then the keys' bytes concatenated; reading it
   back interns in order, so symbols survive the round trip. A cache container stores that as one bytes field.

## Consequences

- deadwood's USR tables, dolly's per-file token tables and corpus assembly, and arcleak's name tables move onto it
  (analyzerkit roadmap 0023, 0024, 0027); the gain to expect is the table's, 2.6 to 6 times, not a whole run's.
- A symbol's text is bytes; a consumer that needs a `String` per lookup loses part of the gain, so the consumers compare
  and hash symbols and resolve text only to print it.

# Seeded randomness & fuzzing

Reproduce a random corpus byte-for-byte, then weaponize it: feed mutated bytes to a parser
and let process survival be the assertion.

## The problem

Property and fuzz tests generate inputs randomly — but a *random* failure you can't
reproduce is nearly worthless. You need two things the language's default RNG can't give
you together: a stream that is **identical on every machine and run** for a given seed, and
the freedom to pin a seed that once found a bug so its exact corpus is regenerated forever.
`SystemRandomNumberGenerator` is non-reproducible; `Hasher`-based derivations are randomized
per process. And across the AD-family this had been solved seven different times — a
canonical SplitMix64 plus six subtly-different re-rolls — so a fix in one never reached the
others.

## The design

``SeededRNG`` is one deterministic generator for the whole family. Its core is SplitMix64
with the published constants, **byte-for-byte identical** to every prior re-roll, so a suite
that migrates to it regenerates the exact same corpus under the same seed. Its helper
surface (``SeededRNG/uniform(_:)``, ``SeededRNG/below(_:)``, ``SeededRNG/int(_:)``,
``SeededRNG/int(in:)``, ``SeededRNG/pick(_:)``, ``SeededRNG/bool()``, ``SeededRNG/byte()``)
is the *union* of the call-site spellings the copies grew, each kept semantically identical
so no migrated sequence shifts.

``Seed`` lets a seed be a raw value *or* a stable name. ``Seed/named(_:)`` derives a 64-bit
value with FNV-1a over the UTF-8 bytes — process-independent, unlike `Hasher` — so a
scattered magic constant becomes a self-documenting `Seed.named("addb.corrupt-file")` that
still reproduces the same stream everywhere. A bug-finding seed that must preserve its exact
historical corpus keeps its raw value via `Seed(0x…)`.

On top sits the corruption engine. ``ByteMutator`` applies overwrite / bit-flip / truncate /
extend edits, with an optional region bound so a checksummed prefix (a database's meta
pages) stays intact while the node region is scrambled. Its default configuration reproduces
the family's canonical four-shape mutator draw-for-draw. The
``fuzzNeverTraps(seed:iterations:edits:mutator:traceEnv:corpus:exercise:)`` driver builds a
fresh corpus each iteration, mutates it, and hands it to your `exercise` closure.

### Why "never traps" is the assertion

The PASS condition is **process survival**. A typed error or a `nil` result inside `exercise`
is expected and fine (the closure swallows its own typed errors); only a *trap* —
precondition, `fatalError`, out-of-bounds, stack overflow — fails the run, by aborting the
process before the driver can return a ``FuzzReport``. That inverts the usual assert: you
are not checking outputs, you are proving the code under test cannot be made to crash. When
the trace environment variable is set, each iteration's mutation list is printed *before* it
runs, so a crashing run's last line is the precise, replayable repro.

## Using it

A reproducible property test:

```swift
var rng = SeededRNG(named: "addb.page-shuffle")
let shuffled = (0 ..< 1000).map { _ in rng.int(in: 0 ... 255) }   // same on every run
```

A crash-injection sweep over a parser, protecting a 16-byte checksummed header:

```swift
let mutator = ByteMutator(region: 16 ..< 4096, allowedEdits: [.overwrite, .bitFlip])
let report = fuzzNeverTraps(
    seed: .named("addb.corrupt-file"),
    iterations: 10_000,
    mutator: mutator,
    corpus: { Array(validPage) },
    exercise: { bytes in _ = try? Page.parse(bytes) })   // typed throw = fine; trap = fail
#expect(report.iterations == 10_000)
```

### When to use it

- Use ``SeededRNG`` + ``Seed`` for any test that generates inputs and must reproduce
  failures; name the seed when it's a fixture, keep it raw when it pins a historical corpus.
- Use ``ByteMutator`` + the byte driver for parsers, decoders, and storage formats — anything
  that reads untrusted bytes. Run the fuzz tag under sanitizers (see <doc:TestTags>) so a
  latent out-of-bounds becomes a hard, traced failure.
- Use the generic `fuzzNeverTraps` overload (grammar-aware generators) when your vectors are
  structured cases rather than byte blobs.

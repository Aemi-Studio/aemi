/// The one deterministic, seedable generator for every AD-family property test,
/// fuzz corpus, and crash-injection sweep — de-duping the seven hand-rolled copies
/// (the canonical `ADDBTestSupport/SplitMix64`, its re-rolls in ADJSON / ADDB /
/// ADSQL / apple-docs, and the two AemiFoundation LCGs).
///
/// The core stream is SplitMix64 with the published constants, byte-for-byte
/// identical to every prior `SplitMix64` re-roll, so a fuzz suite that pins a seed
/// reproduces the exact same corpus after migrating to this type. The helper
/// surface is the *union* of the call-site conventions the copies grew
/// (`next(upTo:)`, `below`, `int`, `int(in:)`, `pick`, `bool`, `byte`), each kept
/// semantically identical to its origin so no migrated sequence shifts.
public struct SeededRNG: RandomNumberGenerator, Sendable {
    private var state: UInt64

    /// Seed from a raw 64-bit value (the form every legacy `SplitMix64(seed:)` used).
    public init(seed: UInt64) { self.state = seed }

    /// Seed from a `Seed` — a raw value or a stable name from the registry.
    public init(seed: Seed) { self.state = seed.rawValue }

    /// The SplitMix64 core. Identical constants and shifts to every prior re-roll,
    /// so the produced stream is unchanged across the migration.
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    // MARK: - Bounded integers (the three legacy spellings, one implementation)

    /// A value in `0 ..< bound` (`bound > 0`). The modulo bias is irrelevant to a
    /// fuzz corpus and keeps the stream fully deterministic. This is the single
    /// implementation behind the legacy `next(upTo:)` (ADDB), `below` (apple-docs),
    /// and `int(_:)` (ADSQL) spellings, which produced identical values.
    public mutating func uniform(_ bound: Int) -> Int {
        precondition(bound > 0, "SeededRNG.uniform requires a positive bound")
        return Int(next() % UInt64(bound))
    }

    /// ADDB's spelling. `0 ..< bound`.
    public mutating func next(upTo bound: Int) -> Int { uniform(bound) }

    /// apple-docs' spelling. `0 ..< bound`.
    public mutating func below(_ bound: Int) -> Int { uniform(bound) }

    /// ADSQL's spelling. `0 ..< bound`.
    public mutating func int(_ bound: Int) -> Int { uniform(bound) }

    /// `lower ... upper` inclusive. The span is computed in 64-bit *unsigned* space, so
    /// even the extreme ranges (`0 ... .max`, `.min ... .max`) draw without trapping on
    /// the `upper - lower + 1` overflow the naive form hits. Every range that fits in
    /// `Int` reproduces the legacy `lower + uniform(width)` value bit-for-bit and consumes
    /// exactly one `next()`, so a pinned fuzz corpus is unchanged.
    public mutating func int(in range: ClosedRange<Int>) -> Int {
        let span = UInt64(
            bitPattern: Int64(truncatingIfNeeded: range.upperBound &- range.lowerBound))
        if span == .max { return Int(truncatingIfNeeded: next()) }  // the full Int range
        let offset = next() % (span &+ 1)
        return range.lowerBound &+ Int(truncatingIfNeeded: offset)
    }

    // MARK: - Element / bit helpers

    /// A uniformly chosen element (`bound > 0`). Indexes via `uniform`, matching the
    /// legacy `pick`.
    public mutating func pick<T>(_ items: [T]) -> T { items[uniform(items.count)] }

    /// `true` when the low bit of `next()` is clear — the legacy `bool()` exactly.
    public mutating func bool() -> Bool { next() & 1 == 0 }

    /// The low byte of `next()` — the legacy `byte()` exactly.
    public mutating func byte() -> UInt8 { UInt8(truncatingIfNeeded: next()) }
}

/// A named or raw seed. `Seed.named(_:)` derives a stable 64-bit value from the
/// name (FNV-1a over the UTF-8 bytes — process-independent, unlike `Hasher`), so a
/// suite can replace a scattered magic constant with a self-documenting
/// `Seed.named("addb.corrupt-file")` and still reproduce the same stream every run.
/// A bug-finding fuzz seed that must preserve its exact historical corpus keeps its
/// raw value via `Seed(0x…)`.
public struct Seed: Sendable, Hashable, RawRepresentable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) { self.rawValue = rawValue }
    public init(_ rawValue: UInt64) { self.rawValue = rawValue }

    /// A stable, process-independent seed derived from `name`. Same name → same
    /// value on every platform and run (no `Hasher` randomization).
    public static func named(_ name: String) -> Seed {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325  // FNV-1a 64 offset basis
        for byte in name.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3  // FNV-1a 64 prime
        }
        return Seed(rawValue: hash)
    }
}

extension SeededRNG {
    /// Seed directly from a name in the registry.
    public init(named name: String) { self.init(seed: Seed.named(name)) }
}

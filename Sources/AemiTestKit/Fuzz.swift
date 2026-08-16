import Foundation

/// A seeded byte-mutation engine: overwrite / bit-flip / truncate / extend, with an
/// optional region bound so the checksummed prefix of a file (e.g. a database's meta
/// pages) stays intact while the node region is scrambled. The default configuration
/// reproduces the AD-family's canonical four-shape mutator (apple-docs
/// `ArchiveFuzzTests`) draw-for-draw, so a suite that migrates to it keeps its exact
/// corpus under the same seed.
public struct ByteMutator: Sendable {
    /// The four mutation shapes a corrupt blob takes.
    public enum Edit: Sendable, Hashable, CaseIterable {
        case overwrite
        case bitFlip
        case truncate
        case extend
    }

    /// One applied edit, for the `*_FUZZ_TRACE` repro line.
    public struct Mutation: Sendable, CustomStringConvertible {
        public let kind: Edit
        public let offset: Int?
        public let value: UInt8?
        public var description: String {
            switch kind {
                case .overwrite: return "set@\(offset ?? -1)=0x\(String(value ?? 0, radix: 16))"
                case .bitFlip: return "flip@\(offset ?? -1)"
                case .truncate: return "truncate"
                case .extend: return "extend"
            }
        }
    }

    /// The sub-range overwrite / bit-flip may touch, and the floor truncate may not
    /// shrink below (`nil` = the whole buffer). Set it to protect a checksummed prefix.
    public var region: Range<Int>?
    /// Which edit shapes to draw from. The default is all four in declaration order, so
    /// the selector is `below(4)` — byte-identical to the canonical apple-docs mutator.
    /// A restricted set (e.g. `[.overwrite]`) gives the ADDB-style in-region overwrite
    /// sweep with no buffer-shrinking edits.
    public var allowedEdits: [Edit]
    /// Maximum tail bytes a single `extend` appends (the legacy cap is 64).
    public var maxExtend: Int

    public init(
        region: Range<Int>? = nil, allowedEdits: [Edit] = Edit.allCases, maxExtend: Int = 64
    ) {
        self.region = region
        self.allowedEdits = allowedEdits.isEmpty ? Edit.allCases : allowedEdits
        self.maxExtend = maxExtend
    }

    /// Applies `count` edits to `bytes` in place, returning the list for a repro trace.
    /// With the default config (all four edits, no region) this reproduces the canonical
    /// four-shape switch draw-for-draw: a selected overwrite/bit-flip/truncate whose
    /// guard fails falls through to `extend`, exactly as the original `case N where …` /
    /// `default` did. Iterative — no recursion.
    @discardableResult
    public func apply(_ count: Int, to bytes: inout [UInt8], using rng: inout SeededRNG)
        -> [Mutation]
    {
        var applied: [Mutation] = []
        applied.reserveCapacity(count)
        let truncateFloor = region?.lowerBound ?? 1
        for _ in 0 ..< count {
            let kind = allowedEdits[rng.below(allowedEdits.count)]
            switch kind {
                case .overwrite where !bytes.isEmpty:
                    let index = pickIndex(bytes.count, &rng)
                    let value = rng.byte()
                    bytes[index] = value
                    applied.append(Mutation(kind: .overwrite, offset: index, value: value))
                case .bitFlip where !bytes.isEmpty:
                    let index = pickIndex(bytes.count, &rng)
                    bytes[index] ^= UInt8(1 << rng.below(8))
                    applied.append(Mutation(kind: .bitFlip, offset: index, value: nil))
                case .truncate where bytes.count > truncateFloor:
                    bytes.removeLast(1 + rng.below(bytes.count - truncateFloor))
                    applied.append(Mutation(kind: .truncate, offset: nil, value: nil))
                default:
                    let extra = 1 + rng.below(maxExtend)
                    for _ in 0 ..< extra { bytes.append(rng.byte()) }
                    applied.append(Mutation(kind: .extend, offset: nil, value: nil))
            }
        }
        return applied
    }

    /// An index to mutate. Region-bounded when `region` is set (and overlaps the
    /// buffer), else uniform over the whole buffer — matching the legacy whole-buffer
    /// draw when no region is configured.
    private func pickIndex(_ count: Int, _ rng: inout SeededRNG) -> Int {
        guard let region, !region.isEmpty else { return rng.below(count) }
        let lower = max(0, region.lowerBound)
        let upper = min(count, region.upperBound)
        guard upper > lower else { return rng.below(count) }
        return lower + rng.below(upper - lower)
    }
}

/// What a fuzz run observed. Reaching a report at all is the PASS signal — a trap
/// (precondition / fatalError / stack overflow / OOB) aborts the process before the
/// loop can return one.
public struct FuzzReport: Sendable, Equatable {
    public let iterations: Int
    public let totalEdits: Int
}

/// The default env var that turns on per-iteration repro tracing when a suite does
/// not pass its own (the legacy suites used `ADSQL_FUZZ_TRACE` / `ADDB_FUZZ_TRACE` /
/// `ADARCHIVE_FUZZ_TRACE`).
public let defaultFuzzTraceEnv = "ADTESTKIT_FUZZ_TRACE"

/// Byte-mutation fuzz driver. Builds a fresh copy of `corpus()` each iteration,
/// applies `edits.lowerBound … edits.upperBound` mutations with `mutator`, then hands
/// the mutated bytes to `exercise`. The PASS condition is process survival: a typed
/// error or `nil` result inside `exercise` is expected-and-fine (the closure swallows
/// its own typed errors), and only a trap fails the run by aborting it. When the
/// `traceEnv` var is set, each iteration's mutation list is printed *before* it runs,
/// so a crashing run's last line is the precise repro.
@discardableResult
public func fuzzNeverTraps(
    seed: Seed,
    iterations: Int,
    edits: ClosedRange<Int> = 1 ... 8,
    mutator: ByteMutator = ByteMutator(),
    traceEnv: String = defaultFuzzTraceEnv,
    corpus: () -> [UInt8],
    exercise: (_ mutated: [UInt8]) -> Void
) -> FuzzReport {
    let trace = ProcessInfo.processInfo.environment[traceEnv] != nil
    let base = corpus()
    var rng = SeededRNG(seed: seed)
    var totalEdits = 0
    for iteration in 0 ..< iterations {
        var blob = base
        let count = rng.int(in: edits)
        let applied = mutator.apply(count, to: &blob, using: &rng)
        totalEdits += applied.count
        if trace {
            let list = applied.map(\.description).joined(separator: ",")
            print("FUZZ i=\(iteration) seed=0x\(String(seed.rawValue, radix: 16)) muts=[\(list)]")
        }
        exercise(blob)
    }
    return FuzzReport(iterations: iterations, totalEdits: totalEdits)
}

/// Generic fuzz driver for suites whose vectors are not byte blobs (e.g. ADSQL's
/// grammar-aware query generators). Owns the seed, iteration budget, trace hook, and
/// survival contract; the suite owns `generate` (build the iteration's case from the
/// RNG) and `exercise` (run it, swallowing expected typed errors). A trap aborts the
/// process — the surviving signal is the seed plus the last traced case.
@discardableResult
public func fuzzNeverTraps<Case>(
    seed: Seed,
    iterations: Int,
    traceEnv: String = defaultFuzzTraceEnv,
    generate: (_ iteration: Int, _ rng: inout SeededRNG) -> Case,
    describe: (Case) -> String = { String(describing: $0) },
    exercise: (Case) -> Void
) -> FuzzReport {
    let trace = ProcessInfo.processInfo.environment[traceEnv] != nil
    var rng = SeededRNG(seed: seed)
    for iteration in 0 ..< iterations {
        let value = generate(iteration, &rng)
        if trace {
            print(
                "FUZZ i=\(iteration) seed=0x\(String(seed.rawValue, radix: 16)): \(describe(value))"
            )
        }
        exercise(value)
    }
    return FuzzReport(iterations: iterations, totalEdits: 0)
}

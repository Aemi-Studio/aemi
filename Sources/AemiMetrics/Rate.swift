/// The best of several rounds of the same work.
public struct Rate: Sendable {
    /// Units of work per second in the fastest round.
    public var perSecond: Double
    /// Retired instructions per unit in the round that retired the fewest; `nil` where the platform does not report
    /// them. Unlike a time it hardly depends on what else the machine is doing.
    public var instructionsPerUnit: Double?
}

/// Runs `body`, which does `units` units of work, `rounds` times and keeps the best round: noise from the machine only
/// ever slows a round, so the fastest is the closest to the work's own cost. Measured with ``ProcessProbe``: wall time,
/// and retired instructions for the whole process, so run it with nothing else going on.
///
/// - Precondition: `rounds` is at least 1 and `units` is positive.
public func measureRate(units: Double, rounds: Int = 5, _ body: () async throws -> Void) async rethrows -> Rate {
    precondition(rounds >= 1, "measureRate needs at least one round")
    precondition(units > 0, "measureRate needs a positive amount of work")
    var fastest = Double.infinity
    var fewest = UInt64.max
    for _ in 0 ..< rounds {
        let start = ProcessProbe.snapshot()
        try await body()
        let delta = ProcessProbe.delta(from: start, to: ProcessProbe.snapshot())
        fastest = min(fastest, Double(delta.wallNanos) / 1e9)
        fewest = min(fewest, delta.instructions)
    }
    return Rate(
        perSecond: units / max(fastest, 1e-9),
        instructionsPerUnit: fewest == 0 || fewest == .max ? nil : Double(fewest) / units)
}

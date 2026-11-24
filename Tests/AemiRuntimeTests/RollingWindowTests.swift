//
//  RollingWindowTests.swift
//  HTTPConcurrencyTests
//
//  The rolling-window boundary shared by the HTTP/2 + HTTP/3 abuse budgets: it rolls over at exactly the
//  interval (not before), restarts at that instant, and a non-advancing clock never rolls (fail-safe).
//  (`rolledOver(at:)` is `mutating`, so each call is taken into a `let` before `#expect`.)
//

import Testing

@testable import AemiRuntime

@Suite("RollingWindow — rate-limit boundary")
struct RollingWindowTests {
    @Test("does not roll over before the interval elapses (boundary)")
    func holdsWithinWindow() {
        var window = RollingWindow(start: 0, interval: 1_000)
        let rolled = window.rolledOver(at: 999)  // one nanosecond shy — must not roll
        #expect(!rolled)
    }

    @Test("rolls over at exactly the interval, then restarts there")
    func rollsOverAtBoundary() {
        var window = RollingWindow(start: 0, interval: 1_000)
        let atBoundary = window.rolledOver(at: 1_000)  // exactly the interval → rolls
        let withinFresh = window.rolledOver(at: 1_999)  // 999 into the fresh window
        let nextBoundary = window.rolledOver(at: 2_000)
        #expect(atBoundary)
        #expect(!withinFresh)
        #expect(nextBoundary)
    }

    @Test("a stalled or backwards clock never rolls over (fail-safe)")
    func nonAdvancingClockNeverRolls() {
        var window = RollingWindow(start: 500, interval: 1_000)
        let same = window.rolledOver(at: 500)  // no time elapsed
        let backwards = window.rolledOver(at: 400)  // backwards — signed math stays ≤ 0
        #expect(!same)
        #expect(!backwards)
    }
}

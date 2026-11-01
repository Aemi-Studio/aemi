import AemiLexers
import Testing

/// A text's line entry states, recorded by a client that scans its lines itself (Atelier's progressive highlighting):
/// exact from the first line on, and extended only by the first line not yet known.
@Suite("Line entry states are recorded in order")
struct LexStatesTests {
    @Test func `a recorded line extends what is known only when it is the next one`() {
        var states = LexStates(lineCount: 3)
        let inComment = LexState(rawValue: 2)
        #expect(states.exactLines == 1 && states.state(at: 0) == .initial)
        states.record(inComment, at: 2)
        #expect(states.exactLines == 1 && states.state(at: 2) == nil)
        states.record(inComment, at: 1)
        #expect(states.exactLines == 2 && states.state(at: 1) == inComment)
        states.record(.initial, at: 3)
        states.record(.initial, at: -1)
        #expect(states.exactLines == 2)
    }
}

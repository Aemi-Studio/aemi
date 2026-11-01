/// The state each line of a text starts in, 4 bytes a line, exact for the first ``exactLines``
/// lines: from any of them a line lexer scans on without the lines before it.
public struct LexStates: Sendable, Equatable {
    public let lineCount: Int
    /// How many lines, from the first, have their exact entry state here.
    public private(set) var exactLines: Int
    private var states: [LexState]

    /// A text of `lineCount` lines, of which only the first one's state is known: every text starts in
    /// ``LexState/initial``.
    public init(lineCount: Int) {
        self.lineCount = max(lineCount, 0)
        states = [LexState](repeating: .initial, count: self.lineCount)
        exactLines = min(self.lineCount, 1)
    }

    /// The state line `line` starts in, when it is known exactly; nil otherwise.
    public func state(at line: Int) -> LexState? {
        line >= 0 && line < exactLines ? states[line] : nil
    }

    /// Records that line `line` starts in `state`, found by scanning from an exact state. Only a line up to the first
    /// one not yet known extends what is known; a line past the text is ignored.
    public mutating func record(_ state: LexState, at line: Int) {
        guard line >= 0, line < lineCount, line <= exactLines else { return }
        states[line] = state
        if line == exactLines { exactLines += 1 }
    }
}

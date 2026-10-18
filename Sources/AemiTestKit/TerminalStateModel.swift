/// A model of the slice of terminal state a reset ladder actually changes.
///
/// This is an **oracle**: a second implementation, written from what a terminal is specified to do,
/// against which the encoder's real output can be compared. Byte-exact tests prove `ask` emits the
/// bytes it means to emit; they cannot prove those bytes mean what we believe. Two independent
/// implementations that agree is evidence, and one implementation agreeing with itself is not.
///
/// The model deliberately understands only what it must: private modes set and reset, the alternate
/// screen, cursor visibility, SGR, and the difference between a reset that preserves history and one
/// that destroys it. Everything else it ignores rather than misinterprets, so an unmodelled sequence
/// can never quietly look like a successful reset.
///
/// Every semantic decision here is a claim about a real terminal, and each is stated in a test. The
/// real-emulator check against kitty remains outstanding; see the roadmap entry.
public struct TerminalStateModel: Sendable {
    /// Private modes a terminal has been told to enable, e.g. 1006 or 2004.
    public private(set) var enabledPrivateModes: Set<Int> = []

    /// The private mode number that switches the alternate screen.
    public static let alternateScreenMode = 1049
    /// The private mode number that switches bracketed paste.
    public static let bracketedPasteMode = 2004
    /// The private mode number that hides the cursor.
    public static let cursorHiddenMode = 25

    /// Whether the terminal is showing the alternate screen.
    public var isAlternateScreen: Bool {
        enabledPrivateModes.contains(Self.alternateScreenMode)
    }

    /// Whether bracketed paste is still reporting pastes as wrapped events.
    public var isBracketedPasteEnabled: Bool {
        enabledPrivateModes.contains(Self.bracketedPasteMode)
    }

    /// Whether the cursor is visible. A terminal starts visible; mode 25 hides it.
    public private(set) var isCursorVisible = true

    /// The graphic rendition attributes currently in force. Empty is the default: no colour, no bold.
    public private(set) var activeGraphicRenditions: Set<Int> = []

    /// Whether the terminal is showing default graphic rendition.
    public var isAtDefaultGraphicRendition: Bool { activeGraphicRenditions.isEmpty }

    /// Whether any private mode is still enabled.
    public var hasNoPrivateModesEnabled: Bool { enabledPrivateModes.isEmpty }

    /// The lines on the visible screen.
    public private(set) var screenLines: [String] = []

    /// The lines scrolled off the top, which the user expects to survive a reset.
    public private(set) var scrollbackLines: [String] = []

    /// The line currently being written.
    private var currentLine = ""

    public init() {}

    /// Puts the model into the state a full-screen program leaves behind when it is killed without
    /// cleaning up: alternate screen on, mouse and paste on, cursor hidden, colours set, and output
    /// the user may still want to read back.
    public mutating func applyFullScreenSession() {
        enabledPrivateModes = [Self.alternateScreenMode, 1000, 1002, 1003, 1006, 1015, Self.bracketedPasteMode]
        isCursorVisible = false
        activeGraphicRenditions = [1, 31, 44]
        scrollbackLines = ["scrolled past line one", "scrolled past line two"]
        screenLines = ["program output on the alternate screen"]
        currentLine = ""
    }

    /// Feeds terminal output into the model, interpreting the sequences a ladder emits.
    ///
    /// Anything unrecognised is ignored rather than guessed at. A parser that invented meaning for
    /// bytes it did not understand would make a reset look successful when nothing had happened.
    public mutating func consume(_ bytes: [UInt8]) {
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            guard byte == 0x1B else {
                appendPrintable(byte)
                index += 1
                continue
            }
            index += 1
            guard index < bytes.count else { return }
            switch bytes[index] {
                case 0x63:  // ESC c — RIS: everything, including history.
                    resetAll(preservingHistory: false)
                    index += 1
                case 0x5B:  // ESC [ — CSI.
                    index = consumeControlSequence(bytes, startingAt: index + 1)
                default:
                    // A two-character escape we do not model; skip it rather than read it as text.
                    index += 1
            }
        }
    }

    // MARK: - Sequences

    /// Consumes a control sequence whose `ESC [` has been read, returning the index to carry on from.
    private mutating func consumeControlSequence(_ bytes: [UInt8], startingAt start: Int) -> Int {
        var index = start
        var privateMarker = false
        while index < bytes.count, bytes[index] == 0x3F || bytes[index] == 0x21 {  // '?' or '!'
            privateMarker = bytes[index] == 0x3F
            index += 1
        }
        var parameterText = ""
        while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x3B {  // digits and ';'
            parameterText.append(Character(UnicodeScalar(bytes[index])))
            index += 1
        }
        guard index < bytes.count else { return index }
        let final = bytes[index]
        let parameters = parameterText.split(separator: ";").compactMap { Int($0) }

        if !privateMarker, parameterText.isEmpty, final == 0x70 {  // CSI ! p — DECSTR
            resetAll(preservingHistory: true)
        } else if final == 0x68 || final == 0x6C {  // h / l
            setPrivateModes(parameters, enabled: final == 0x68)
        } else if final == 0x6D {  // m — SGR
            applyGraphicRendition(parameters)
        }
        return index + 1
    }

    // MARK: - Semantics

    private mutating func setPrivateModes(_ parameters: [Int], enabled: Bool) {
        let modes = parameters.isEmpty ? [0] : parameters
        for mode in modes {
            if mode == Self.cursorHiddenMode {
                // Mode 25 is inverted relative to the other private modes: `h` SHOWS the cursor
                // (DECTCEM set) and `l` hides it. Reading it the obvious way hides the cursor at
                // exactly the moment the terminal is trying to show it again.
                isCursorVisible = enabled
                continue
            }
            if enabled {
                enabledPrivateModes.insert(mode)
            } else {
                enabledPrivateModes.remove(mode)
            }
        }
    }

    private mutating func applyGraphicRendition(_ parameters: [Int]) {
        // An empty parameter list is `ESC [ m`, which means "no attributes".
        activeGraphicRenditions = parameters.isEmpty ? [] : Set(parameters)
    }

    /// DECSTR (`CSI ! p`) resets modes, cursor and attributes but keeps the screen and the history.
    /// RIS (`ESC c`) resets those too and additionally discards both.
    private mutating func resetAll(preservingHistory: Bool) {
        enabledPrivateModes.removeAll()
        isCursorVisible = true
        activeGraphicRenditions.removeAll()
        if !preservingHistory {
            screenLines.removeAll()
            scrollbackLines.removeAll()
            currentLine = ""
        }
    }

    private mutating func appendPrintable(_ byte: UInt8) {
        guard byte >= 0x20, byte <= 0x7E else { return }
        currentLine.append(Character(UnicodeScalar(byte)))
        if screenLines.isEmpty {
            screenLines = [currentLine]
        } else {
            screenLines[screenLines.count - 1] = currentLine
        }
    }
}

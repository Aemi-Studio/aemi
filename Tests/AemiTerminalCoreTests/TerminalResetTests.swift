internal import AemiTerminalCore
import Testing

/// The reset ladder is the recovery primitive for a terminal left in a bad state: after a crash the
/// user's shell is sitting in the alternate screen with mouse reporting and bracketed paste still
/// enabled, and nothing has turned them off.
///
/// Escalation is cheapest first. Each tier is byte-exact, because for an escape sequence the exact
/// bytes and their order ARE the behaviour: a terminal is not a function that takes an argument, it
/// is a device that reads bytes in sequence.
@Suite("The terminal reset ladder")
struct TerminalResetTests {
    /// `ESC [ ? 1049 l` — leave the alternate screen.
    private static let leaveAlternateScreen: [UInt8] = [0x1B, 0x5B, 0x3F, 0x31, 0x30, 0x34, 0x39, 0x6C]
    /// Mouse reporting, every tracking mode a TUI can turn on, and both the 1015 legacy encoding.
    private static let disableMouse: [UInt8] = [
        0x1B, 0x5B, 0x3F, 0x31, 0x30, 0x30, 0x30, 0x6C,  // ?1000 l
        0x1B, 0x5B, 0x3F, 0x31, 0x30, 0x30, 0x32, 0x6C,  // ?1002 l
        0x1B, 0x5B, 0x3F, 0x31, 0x30, 0x30, 0x33, 0x6C,  // ?1003 l
        0x1B, 0x5B, 0x3F, 0x31, 0x30, 0x30, 0x36, 0x6C,  // ?1006 l
        0x1B, 0x5B, 0x3F, 0x31, 0x30, 0x31, 0x35, 0x6C  // ?1015 l
    ]
    /// `ESC [ ? 2004 l` — bracketed paste off.
    private static let disableBracketedPaste: [UInt8] = [0x1B, 0x5B, 0x3F, 0x32, 0x30, 0x30, 0x34, 0x6C]
    /// `ESC [ m` — SGR back to default, so no colour or bold leaks into the shell.
    private static let defaultGraphicRendition: [UInt8] = [0x1B, 0x5B, 0x6D]
    /// `ESC [ ? 25 h` — cursor visible again.
    private static let showCursor: [UInt8] = [0x1B, 0x5B, 0x3F, 0x32, 0x35, 0x68]

    @Test func `the selective tier turns off every mode a TUI turns on`() {
        let bytes = TerminalResetLadder.escapeBytes(for: .selectiveCleanup)

        #expect(
            bytes == Self.leaveAlternateScreen + Self.disableMouse + Self.disableBracketedPaste
                + Self.defaultGraphicRendition + Self.showCursor)
    }

    @Test func `the selective tier leaves the cursor visible and the colours default`() {
        // A shell that comes back bold, coloured, or with no cursor is a shell the user has to fix
        // by hand, so these two are not optional extras on the way out.
        let bytes = TerminalResetLadder.escapeBytes(for: .selectiveCleanup)

        #expect(bytes.contains(Self.showCursor))
        #expect(bytes.contains(Self.defaultGraphicRendition))
    }

    @Test func `the soft tier is DECSTR and not a full reset`() {
        // `ESC [ ! p` is DECSTR: it resets modes, cursor and attributes while PRESERVING screen
        // contents and scrollback. A full reset here would throw away the user's scrollback to fix a
        // mode, which is a far worse outcome than the one being repaired.
        #expect(TerminalResetLadder.escapeBytes(for: .softReset) == [0x1B, 0x5B, 0x21, 0x70])
    }

    @Test func `the full tier is RIS`() {
        // `ESC c` — last resort only. Destroys scrollback, and the user sees it happen.
        #expect(TerminalResetLadder.escapeBytes(for: .fullReset) == [0x1B, 0x63])
    }

    @Test func `the soft tier never emits a full reset`() {
        // The tiers exist so that scrollback is spared. If a full reset can leak into a lower tier
        // the ladder has quietly become the destructive thing it was written to avoid.
        #expect(
            !TerminalResetLadder.escapeBytes(for: .selectiveCleanup)
                .contains(TerminalResetLadder.escapeBytes(for: .fullReset)))
        #expect(
            !TerminalResetLadder.escapeBytes(for: .softReset).contains(TerminalResetLadder.escapeBytes(for: .fullReset))
        )
    }

    @Test func `the ladder escalates cheapest first`() {
        // Ordering is the whole design: the user pays for scrollback only after the cheaper tiers
        // have already failed, and never in the normal path at all.
        #expect(TerminalResetLadder.tiers == [.selectiveCleanup, .softReset, .fullReset])
    }

    @Test func `the ladder stops at the tier it is given`() {
        #expect(
            TerminalResetLadder.escapeBytes(upTo: .selectiveCleanup)
                == TerminalResetLadder.escapeBytes(for: .selectiveCleanup))
        #expect(
            TerminalResetLadder.escapeBytes(upTo: .softReset) == TerminalResetLadder.escapeBytes(for: .selectiveCleanup)
                + TerminalResetLadder.escapeBytes(for: .softReset))
    }

    @Test func `the full ladder ends with the full reset`() {
        // The destructive tier must be last, or a routine teardown would destroy scrollback on the
        // way out of every session.
        let ladder = TerminalResetLadder.escapeBytes(upTo: .fullReset)
        #expect(Array(ladder.suffix(2)) == [0x1B, 0x63])
    }

    @Test func `every tier is non-empty`() {
        // A tier that writes nothing is a tier that silently fails to reset anything.
        for tier in TerminalResetLadder.tiers {
            #expect(!TerminalResetLadder.escapeBytes(for: tier).isEmpty, "\(tier) emits no bytes")
        }
    }
}

/// A terminal left in a bad state, and the ladder that brings it back.
///
/// When a terminal program dies without cleaning up, the user's shell is left sitting in the
/// alternate screen with mouse reporting and bracketed paste still enabled, and nothing will turn
/// them off. `restoreMode()` alone cannot fix this: it restores `termios`, which is a property of the
/// terminal emulator's input handling, not of the private modes a program switched on.
///
/// The recovery is a ladder, escalating cheapest first, so the user pays for the destructive tier
/// only after the cheap ones have already failed — and never in the normal path at all.
public enum TerminalResetTier: String, Sendable, CaseIterable, Equatable {
    /// Turn off, individually and by name, the private modes a full-screen program turns on.
    case selectiveCleanup
    /// DECSTR (`ESC [ ! p`): reset modes, cursor and attributes, preserving contents and scrollback.
    case softReset
    /// RIS (`ESC c`): reset everything, destroying scrollback. Last resort only.
    case fullReset
}

/// The reset ladder: what to write, and in what order, to bring a terminal back.
///
/// Every tier is a plain value here. Nothing in this file opens a file descriptor, so the bytes can
/// be proved exactly in a unit test; whether a terminal actually behaves as claimed is a separate
/// question, answered against a real PTY in the I/O tier above this one.
public enum TerminalResetLadder {
    /// The tiers in escalation order. The order is the entire design and is covered by a test.
    public static let tiers: [TerminalResetTier] = [.selectiveCleanup, .softReset, .fullReset]

    /// The bytes that apply a single tier.
    public static func escapeBytes(for tier: TerminalResetTier) -> [UInt8] {
        switch tier {
            case .selectiveCleanup: selectiveCleanup
            case .softReset: [0x1B, 0x5B, 0x21, 0x70]
            case .fullReset: [0x1B, 0x63]
        }
    }

    /// The bytes that apply every tier up to and including `tier`.
    ///
    /// Escalation is cumulative on purpose: a tier that failed to fix the terminal leaves it in the
    /// same state, so the next tier starts from where the last one stopped rather than from scratch.
    public static func escapeBytes(upTo tier: TerminalResetTier) -> [UInt8] {
        let end = tiers.firstIndex(of: tier).map { $0 + 1 } ?? tiers.count
        return tiers.prefix(end).flatMap(escapeBytes(for:))
    }

    /// Every private mode a full-screen program is likely to have turned on, named and turned off.
    ///
    /// Mouse tracking has several modes and they are not exclusive — a program that enabled 1003 may
    /// also have enabled 1000 — so all of them are cleared. SGR (1006) and urxvt (1015) are included
    /// because an emulator given the wrong mouse encoding will otherwise keep reporting events.
    ///
    /// The cursor is shown and SGR returned to default last, so that a terminal which stops parsing
    /// part-way through still ends up visible.
    private static let selectiveCleanup: [UInt8] = [
        0x1B, 0x5B, 0x3F, 0x31, 0x30, 0x34, 0x39, 0x6C,  // ESC [ ? 1049 l — leave the alternate screen
        0x1B, 0x5B, 0x3F, 0x31, 0x30, 0x30, 0x30, 0x6C,  // ESC [ ? 1000 l — mouse click tracking
        0x1B, 0x5B, 0x3F, 0x31, 0x30, 0x30, 0x32, 0x6C,  // ESC [ ? 1002 l — mouse drag tracking
        0x1B, 0x5B, 0x3F, 0x31, 0x30, 0x30, 0x33, 0x6C,  // ESC [ ? 1003 l — mouse motion tracking
        0x1B, 0x5B, 0x3F, 0x31, 0x30, 0x30, 0x36, 0x6C,  // ESC [ ? 1006 l — SGR mouse encoding
        0x1B, 0x5B, 0x3F, 0x31, 0x30, 0x31, 0x35, 0x6C,  // ESC [ ? 1015 l — urxvt mouse encoding
        0x1B, 0x5B, 0x3F, 0x32, 0x30, 0x30, 0x34, 0x6C,  // ESC [ ? 2004 l — bracketed paste
        0x1B, 0x5B, 0x6D,  // ESC [ m — graphic rendition back to default
        0x1B, 0x5B, 0x3F, 0x32, 0x35, 0x68  // ESC [ ? 25 h — cursor visible
    ]
}

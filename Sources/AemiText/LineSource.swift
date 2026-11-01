/// Lines that lend their bytes: a text split into lines once, read a line at a time without making strings. A diff
/// reads its lines through it (`AemiDiff`), from a string's ``TextLines`` or from an editor's own storage, such as
/// TerminalKit's rope.
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
public protocol LineSource: Sendable {
    var lineCount: Int { get }
    /// Lends the UTF-8 bytes of line `index`, without its terminator.
    /// - Precondition: `index` is in `0 ..< lineCount`.
    func withLineBytes<R, E: Error>(at index: Int, _ body: (Span<UInt8>) throws(E) -> R) throws(E) -> R
}

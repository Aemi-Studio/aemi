// Red stub (ADR 0019): the public surface, with bodies that return wrong answers.

/// An interned key: a dense number from 0, in the order keys were first interned.
public struct Symbol: Hashable, Comparable, Sendable {
    public let rawValue: UInt32

    @inlinable public init(rawValue: UInt32) { self.rawValue = rawValue }

    @inlinable public static func < (lhs: Symbol, rhs: Symbol) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Why serialized bytes were refused.
public enum InternerFormatError: Error, Equatable, Sendable {
    /// The bytes end inside a count, a length or a key.
    case truncated
    /// Bytes remain after the last key.
    case trailingBytes
    /// A key appears twice, so the symbols could not be the ones written.
    case duplicateKey(Symbol)
}

/// Interns UTF-8 keys as ``Symbol``s, for one owner (ADR 0019): key bytes copied into chunks that never move, an
/// open-addressing table hashed with `WyHash`. Never makes a `String` unless asked for one.
public final class Interner {
    /// An interner with room for `capacity` keys and `byteCapacity` bytes of them before it allocates again.
    public init(capacity: Int = 0, byteCapacity: Int = 0) {}

    /// Reads ``serialized()``'s bytes back: the same keys under the same symbols.
    public convenience init(serialized bytes: [UInt8]) throws(InternerFormatError) { self.init() }

    /// How many distinct keys it holds.
    public var count: Int { 0 }

    /// `bytes`' symbol, interning them if new.
    public func intern(_ bytes: UnsafeRawBufferPointer) -> Symbol { Symbol(rawValue: 0) }

    /// `text`'s UTF-8 symbol, interning it if new.
    public func intern(_ text: some StringProtocol) -> Symbol { Symbol(rawValue: 0) }

    /// `bytes`' symbol, or nil when they were never interned.
    public func symbol(for bytes: UnsafeRawBufferPointer) -> Symbol? { nil }

    /// `text`'s symbol, or nil when it was never interned.
    public func symbol(for text: some StringProtocol) -> Symbol? { nil }

    /// Calls `body` with `symbol`'s bytes, valid during the call.
    public func withBytes<R, E: Error>(of symbol: Symbol, _ body: (UnsafeRawBufferPointer) throws(E) -> R) throws(E)
        -> R
    {
        try unsafe body(UnsafeRawBufferPointer(start: nil, count: 0))
    }

    /// `symbol`'s key as a `String` (the key decoded as UTF-8, repairing invalid sequences).
    public func string(of symbol: Symbol) -> String { "" }

    /// An immutable, shareable copy of the table; the key bytes are shared, not copied.
    public func freeze() -> FrozenInterner { FrozenInterner() }

    /// The keys, in symbol order: the count, each length as a LEB128 varint, then the bytes concatenated.
    public func serialized() -> [UInt8] { [] }

    /// Interners filled in input order, merged on `workers` threads: the symbols one interner reading every input in
    /// order would give, whatever `workers` is, and for each input the merged symbol of each of its local symbols.
    /// The inputs' key bytes are shared, not copied; the inputs may be read but no longer interned into.
    public static func merge(_ interners: [Interner], workers: Int = 4) -> MergedInterner {
        MergedInterner(interner: FrozenInterner(), remaps: [])
    }
}

/// The result of ``Interner/merge(_:workers:)``.
public struct MergedInterner: Sendable {
    public let interner: FrozenInterner
    /// `remaps[input][local]` is the merged symbol of input `input`'s local symbol `local`.
    public let remaps: [[Symbol]]
}

/// An interner that no longer changes, for lookups from any thread.
public final class FrozenInterner: Sendable {
    init() {}

    public var count: Int { 0 }

    public func symbol(for bytes: UnsafeRawBufferPointer) -> Symbol? { nil }

    public func symbol(for text: some StringProtocol) -> Symbol? { nil }

    public func withBytes<R, E: Error>(of symbol: Symbol, _ body: (UnsafeRawBufferPointer) throws(E) -> R) throws(E)
        -> R
    {
        try unsafe body(UnsafeRawBufferPointer(start: nil, count: 0))
    }

    public func string(of symbol: Symbol) -> String { "" }

    public func serialized() -> [UInt8] { [] }
}

internal import AemiKernel

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
/// open-addressing table hashed with ``WyHash``. Never makes a `String` unless asked for one.
///
/// Not `Sendable`: give each task its own, then ``merge(_:workers:)`` them or ``freeze()`` one for readers.
public final class Interner {
    let table: Table
    private let arena: Arena

    /// An interner with room for `capacity` keys and `byteCapacity` bytes of them before it allocates again.
    public init(capacity: Int = 0, byteCapacity: Int = 0) {
        arena = Arena(byteCapacity: byteCapacity)
        table = Table(capacity: capacity, arenas: [arena])
    }

    /// How many distinct keys it holds.
    public var count: Int { table.count }

    /// `bytes`' symbol, interning them if new.
    public func intern(_ bytes: UnsafeRawBufferPointer) -> Symbol {
        let hash = unsafe WyHash.hash(bytes)
        let found = unsafe table.find(bytes, hash: hash)
        if let symbol = found.symbol { return Symbol(rawValue: UInt32(truncatingIfNeeded: symbol)) }
        let start = unsafe arena.store(bytes)
        let symbol = unsafe table.insert(start: start, length: bytes.count, hash: hash, at: found.slot)
        return Symbol(rawValue: UInt32(truncatingIfNeeded: symbol))
    }

    /// `text`'s UTF-8 symbol, interning it if new.
    public func intern(_ text: some StringProtocol) -> Symbol {
        if let symbol = text.utf8.withContiguousStorageIfAvailable({ unsafe intern(UnsafeRawBufferPointer($0)) }) {
            return symbol
        }
        return Array(text.utf8).withUnsafeBytes { unsafe intern($0) }
    }

    /// `bytes`' symbol, or nil when they were never interned.
    public func symbol(for bytes: UnsafeRawBufferPointer) -> Symbol? { unsafe table.lookup(bytes) }

    /// `text`'s symbol, or nil when it was never interned.
    public func symbol(for text: some StringProtocol) -> Symbol? { table.lookup(text) }

    /// Calls `body` with `symbol`'s bytes, valid during the call.
    public func withBytes<R, E: Error>(of symbol: Symbol, _ body: (UnsafeRawBufferPointer) throws(E) -> R) throws(E)
        -> R
    {
        try unsafe body(table.checkedBytes(of: symbol))
    }

    /// `symbol`'s key as a `String` (the key decoded as UTF-8, repairing invalid sequences).
    public func string(of symbol: Symbol) -> String { table.string(of: symbol) }

    /// An immutable, shareable copy of the table; the key bytes are shared, not copied.
    public func freeze() -> FrozenInterner { FrozenInterner(table: table.copy()) }

    /// The keys, in symbol order: the count, each length as a LEB128 varint, then the bytes concatenated.
    public func serialized() -> [UInt8] { table.serialized() }

    /// Reads ``serialized()``'s bytes back: the same keys under the same symbols.
    public convenience init(serialized bytes: [UInt8]) throws(InternerFormatError) {
        let layout = try SerializedLayout(bytes)
        self.init(capacity: layout.lengths.count, byteCapacity: layout.keyBytes)
        // The first key that interned to an earlier symbol, if any.
        let duplicate: Int? = bytes.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Int? in
            var offset = layout.keysStart
            for (index, length) in layout.lengths.enumerated() {
                let key = unsafe UnsafeRawBufferPointer(rebasing: buffer[offset ..< (offset + length)])
                guard unsafe intern(key).rawValue == UInt32(index) else { return index }
                offset += length
            }
            return nil
        }
        if let duplicate { throw .duplicateKey(Symbol(rawValue: UInt32(duplicate))) }
    }

    /// Interners filled in input order, merged on `workers` threads: the symbols one interner reading every input in
    /// order would give, whatever `workers` is, and for each input the merged symbol of each of its local symbols. The
    /// inputs' key bytes are shared, not copied.
    public static func merge(_ interners: [Interner], workers: Int = 4) -> MergedInterner {
        Merge.run(interners.map(\.table), workers: workers)
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
    let table: Table

    init(table: Table) { self.table = table }

    public var count: Int { table.count }

    public func symbol(for bytes: UnsafeRawBufferPointer) -> Symbol? { unsafe table.lookup(bytes) }

    public func symbol(for text: some StringProtocol) -> Symbol? { table.lookup(text) }

    public func withBytes<R, E: Error>(of symbol: Symbol, _ body: (UnsafeRawBufferPointer) throws(E) -> R) throws(E)
        -> R
    {
        try unsafe body(table.checkedBytes(of: symbol))
    }

    public func string(of symbol: Symbol) -> String { table.string(of: symbol) }

    public func serialized() -> [UInt8] { table.serialized() }
}

extension Table {
    func lookup(_ bytes: UnsafeRawBufferPointer) -> Symbol? {
        let found = unsafe find(bytes, hash: WyHash.hash(bytes))
        return found.symbol.map { Symbol(rawValue: UInt32(truncatingIfNeeded: $0)) }
    }

    func lookup(_ text: some StringProtocol) -> Symbol? {
        if let found = text.utf8.withContiguousStorageIfAvailable({ unsafe lookup(UnsafeRawBufferPointer($0)) }) {
            return found
        }
        return Array(text.utf8).withUnsafeBytes { unsafe lookup($0) }
    }

    func checkedBytes(of symbol: Symbol) -> UnsafeRawBufferPointer {
        precondition(Int(symbol.rawValue) < count, "symbol \(symbol.rawValue) was not interned here")
        return unsafe bytes(of: Int(symbol.rawValue))
    }

    func string(of symbol: Symbol) -> String {
        unsafe String(decoding: checkedBytes(of: symbol), as: UTF8.self)
    }
}

/// A borrowed run of bytes, read with a bounds check on every access, in release builds too. Promoted from AemiRegex, where the
/// Pike VM reads through it as the bounds-checked reference the faster engines are tested against (aemi ADR 0018).
///
/// `@safe` states the interface is memory safe: the only way to read through it is the checked subscript. The buffer must outlive
/// the value; both are made inside a `withUnsafeBufferPointer`-style scope and never stored. ``buffer`` is for code that does its own
/// bounds reasoning, and using it is unsafe.
@safe public struct CheckedBytes: RandomAccessCollection {
    /// The underlying bytes.
    @unsafe public let buffer: UnsafeBufferPointer<UInt8>

    @inlinable
    public init(_ buffer: UnsafeBufferPointer<UInt8>) { unsafe self.buffer = buffer }

    @inlinable
    public var startIndex: Int { 0 }
    @inlinable
    public var endIndex: Int { unsafe buffer.count }
    @inlinable
    public var count: Int { unsafe buffer.count }

    /// The byte at `index`. Stops the program if the index is outside the buffer.
    @inlinable
    public subscript(index: Int) -> UInt8 {
        let size = unsafe buffer.count
        precondition(index >= 0 && index < size, "byte index \(index) outside a buffer of \(size)")
        return unsafe buffer[index]
    }
}

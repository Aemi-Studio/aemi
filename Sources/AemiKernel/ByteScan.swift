public import AemiKernels

/// Safe, range-taking entry points to the byte kernels, with a SWAR front for short runs (ADR 0031).
///
/// A parser searches `bytes[cursor ..< end]` many times per line, and most searches end within a few bytes: a C kernel call then
/// costs more than the search. Each function here looks at the first ``shortRun`` bytes eight at a time with ``SWAR`` (AemiJSON's
/// `stringStopMask` and AemiHMMML's profile measured the same crossover) and only then calls the SIMD kernel. Indices are
/// absolute, `end` is clamped to the input, an empty range returns its end, and no caller needs a pointer: AemiMarkdown's and
/// AemiHMMML's private `ByteScan`s were this file twice.
public enum ByteScan {
    /// Bytes searched with SWAR before a kernel is called.
    @usableFromInline static let shortRun = 32

    // MARK: Any of five bytes

    /// The index in `bytes[start ..< end]` of the first byte equal to any of the needles (repeat one to use fewer), or the end.
    @inlinable
    // swiftlint:disable:next function_parameter_count
    public static func firstIndexOfAny(
        in bytes: [UInt8],
        from start: Int,
        to end: Int = .max,
        _ n0: UInt8,
        _ n1: UInt8,
        _ n2: UInt8,
        _ n3: UInt8,
        _ n4: UInt8
    ) -> Int {
        bytes.withUnsafeBufferPointer { unsafe anyOf($0, start, end, n0, n1, n2, n3, n4) }
    }

    /// As ``firstIndexOfAny(in:from:to:_:_:_:_:_:)-([UInt8],_,_,_,_,_,_,_)``.
    @inlinable
    // swiftlint:disable:next function_parameter_count
    public static func firstIndexOfAny(
        in bytes: ContiguousArray<UInt8>,
        from start: Int,
        to end: Int = .max,
        _ n0: UInt8,
        _ n1: UInt8,
        _ n2: UInt8,
        _ n3: UInt8,
        _ n4: UInt8
    ) -> Int {
        bytes.withUnsafeBufferPointer { unsafe anyOf($0, start, end, n0, n1, n2, n3, n4) }
    }

    @inlinable
    // swiftlint:disable:next function_parameter_count
    static func anyOf(
        _ buffer: UnsafeBufferPointer<UInt8>,
        _ start: Int,
        _ end: Int,
        _ n0: UInt8,
        _ n1: UInt8,
        _ n2: UInt8,
        _ n3: UInt8,
        _ n4: UInt8
    ) -> Int {
        unsafe front(buffer, start, end) { word in
            SWAR.equals(word, n0) | SWAR.equals(word, n1) | SWAR.equals(word, n2) | SWAR.equals(word, n3)
                | SWAR.equals(word, n4)
        } kernel: { base, count in
            unsafe AemiKernels.firstIndexOfAny(base: base, count: count, n0, n1, n2, n3, n4)
        }
    }

    /// As ``firstIndexOfAny(in:from:to:_:_:_:_:_:)-([UInt8],_,_,_,_,_,_,_)``, over a buffer: for a parser that holds a pointer to
    /// its source (CSVCoder's fields, AemiJSON's tape builder).
    @inlinable
    // swiftlint:disable:next function_parameter_count
    public static func firstIndexOfAny(
        in buffer: UnsafeBufferPointer<UInt8>,
        from start: Int,
        to end: Int = .max,
        _ n0: UInt8,
        _ n1: UInt8,
        _ n2: UInt8,
        _ n3: UInt8,
        _ n4: UInt8
    ) -> Int {
        unsafe anyOf(buffer, start, end, n0, n1, n2, n3, n4)
    }

    // MARK: One byte

    /// The index in `bytes[start ..< end]` of the first byte equal to `needle`, or the end.
    @inlinable
    public static func firstIndex(of needle: UInt8, in bytes: [UInt8], from start: Int, to end: Int = .max) -> Int {
        bytes.withUnsafeBufferPointer { buffer in
            unsafe front(buffer, start, end) {
                SWAR.equals($0, needle)
            } kernel: { base, count in
                unsafe AemiKernels.firstIndexOfByte(base: base, count: count, needle: needle)
            }
        }
    }

    /// As ``firstIndex(of:in:from:to:)-(_,[UInt8],_,_)``, over a buffer.
    @inlinable
    public static func firstIndex(
        of needle: UInt8,
        in buffer: UnsafeBufferPointer<UInt8>,
        from start: Int,
        to end: Int = .max
    )
        -> Int
    {
        unsafe front(buffer, start, end) {
            SWAR.equals($0, needle)
        } kernel: { base, count in
            unsafe AemiKernels.firstIndexOfByte(base: base, count: count, needle: needle)
        }
    }

    // MARK: Controls and five bytes

    /// The index in `bytes[start ..< end]` of the first control byte (`< 0x20`) or byte equal to a needle, or the end.
    @inlinable
    // swiftlint:disable:next function_parameter_count
    public static func indexOfControlOrAny(
        in bytes: [UInt8],
        from start: Int,
        to end: Int = .max,
        _ n0: UInt8,
        _ n1: UInt8,
        _ n2: UInt8,
        _ n3: UInt8,
        _ n4: UInt8
    ) -> Int {
        bytes.withUnsafeBufferPointer { buffer in
            unsafe front(buffer, start, end) { word in
                SWAR.lessThan(word, 0x20) | SWAR.equals(word, n0) | SWAR.equals(word, n1) | SWAR.equals(word, n2)
                    | SWAR.equals(word, n3) | SWAR.equals(word, n4)
            } kernel: { base, count in
                unsafe AemiKernels.indexOfControlOrAny(base: base, count: count, n0, n1, n2, n3, n4)
            }
        }
    }

    // MARK: Runs

    /// The index in `bytes` at or after `start` (before `end`) of the first byte that is neither `a` nor `b`, or the end: the end
    /// of a run of indentation. Exact per-lane SWAR (``SWAR/neitherLanes(_:_:_:)``) for any length, since a run is usually short.
    @inlinable
    public static func firstIndexNotEither(
        _ a: UInt8,
        _ b: UInt8,
        in bytes: [UInt8],
        from start: Int,
        to end: Int = .max
    ) -> Int {
        let end = Swift.min(end, bytes.count)
        guard start >= 0, start < end else { return Swift.max(start, Swift.max(end, 0)) }
        // A run of one or none is the common case and costs no pointer.
        let first = bytes[start]
        guard first == a || first == b else { return start }
        return bytes.withUnsafeBufferPointer { buffer -> Int in
            guard let base = buffer.baseAddress else { return end }
            var index = start
            while index + 8 <= end {
                // SAFETY: `index + 8 <= end <= buffer.count`.
                let word = UInt64(littleEndian: unsafe UnsafeRawPointer(base + index).loadUnaligned(as: UInt64.self))
                let lanes = SWAR.neitherLanes(word, a, b)
                if lanes != 0 { return index + lanes.trailingZeroBitCount >> 3 }
                index += 8
            }
            while index < end, unsafe base[index] == a || base[index] == b { index += 1 }
            return index
        }
    }

    /// The index in `bytes[start ..< end]` of the first byte in `set`, or the end.
    @inlinable
    public static func firstIndex(
        inSet set: AemiKernels.ByteSet,
        in bytes: [UInt8],
        from start: Int,
        to end: Int = .max
    ) -> Int {
        bytes.withUnsafeBufferPointer { buffer in
            unsafe clamp(buffer, start, end) { base, count in
                unsafe AemiKernels.firstIndex(inSet: set, base: base, count: count)
            }
        }
    }

    /// The index in `bytes[start ..< end]` of the first byte NOT in `set`, or the end: the end of a run of the set's bytes.
    @inlinable
    public static func firstIndex(
        notInSet set: AemiKernels.ByteSet,
        in bytes: [UInt8],
        from start: Int,
        to end: Int = .max
    ) -> Int {
        bytes.withUnsafeBufferPointer { buffer in
            unsafe clamp(buffer, start, end) { base, count in
                unsafe AemiKernels.firstIndex(notInSet: set, base: base, count: count)
            }
        }
    }

    /// As ``firstIndex(inSet:in:from:to:)-([UInt8],_,_,_)``.
    @inlinable
    public static func firstIndex(
        inSet set: AemiKernels.ByteSet,
        in bytes: ContiguousArray<UInt8>,
        from start: Int,
        to end: Int = .max
    ) -> Int {
        bytes.withUnsafeBufferPointer { buffer in
            unsafe clamp(buffer, start, end) { base, count in
                unsafe AemiKernels.firstIndex(inSet: set, base: base, count: count)
            }
        }
    }

    /// As ``firstIndex(notInSet:in:from:to:)-([UInt8],_,_,_)``.
    @inlinable
    public static func firstIndex(
        notInSet set: AemiKernels.ByteSet,
        in bytes: ContiguousArray<UInt8>,
        from start: Int,
        to end: Int = .max
    ) -> Int {
        bytes.withUnsafeBufferPointer { buffer in
            unsafe clamp(buffer, start, end) { base, count in
                unsafe AemiKernels.firstIndex(notInSet: set, base: base, count: count)
            }
        }
    }

    /// As ``firstInvalidUTF8(in:from:to:)-([UInt8],_,_)``.
    @inlinable
    public static func firstInvalidUTF8(in bytes: ContiguousArray<UInt8>, from start: Int = 0, to end: Int = .max)
        -> Int?
    {
        let clampedEnd = Swift.min(end, bytes.count)
        let found = bytes.withUnsafeBufferPointer { buffer in
            unsafe clamp(buffer, start, end) { base, count in
                unsafe AemiKernels.firstInvalidUTF8(base: base, count: count)
            }
        }
        return found < clampedEnd ? found : nil
    }

    /// The index in `bytes[start ..< end]` of the first byte that is not part of well-formed UTF-8, or nil when the range is.
    /// A sequence cut by `start` or `end` counts as ill-formed: pass whole characters.
    @inlinable
    public static func firstInvalidUTF8(in bytes: [UInt8], from start: Int = 0, to end: Int = .max) -> Int? {
        let clampedEnd = Swift.min(end, bytes.count)
        let found = bytes.withUnsafeBufferPointer { buffer in
            unsafe clamp(buffer, start, end) { base, count in
                unsafe AemiKernels.firstInvalidUTF8(base: base, count: count)
            }
        }
        return found < clampedEnd ? found : nil
    }

    // MARK: Shared fronts

    /// SWAR over the first ``shortRun`` bytes of the range (`mask` returns `0x80` in the first stop lane, as ``SWAR`` does), then
    /// `kernel` over the rest; an absolute index, or the clamped end.
    @inlinable @inline(__always)
    static func front(
        _ buffer: UnsafeBufferPointer<UInt8>,
        _ start: Int,
        _ end: Int,
        mask: (UInt64) -> UInt64,
        kernel: (UnsafePointer<UInt8>, Int) -> Int
    ) -> Int {
        let end = Swift.min(end, buffer.count)
        guard start >= 0, start < end, let base = buffer.baseAddress else { return Swift.max(start, Swift.max(end, 0)) }
        var index = start
        let words = Swift.min(end, start &+ shortRun)
        while index + 8 <= words {
            // SAFETY: `index + 8 <= end <= buffer.count`, so the eight bytes are inside the buffer.
            let word = UInt64(littleEndian: unsafe UnsafeRawPointer(base + index).loadUnaligned(as: UInt64.self))
            let stop = mask(word)
            if stop != 0 { return index + stop.trailingZeroBitCount >> 3 }
            index += 8
        }
        guard index < end else { return end }
        // SAFETY: `start <= index < end <= buffer.count`, so `base + index` is valid for `end - index` bytes.
        let found = unsafe kernel(base + index, end - index)
        return index + found
    }

    /// `kernel` over the range, clamped; an absolute index, or the clamped end.
    @inlinable @inline(__always)
    static func clamp(
        _ buffer: UnsafeBufferPointer<UInt8>,
        _ start: Int,
        _ end: Int,
        _ kernel: (UnsafePointer<UInt8>, Int) -> Int
    ) -> Int {
        let end = Swift.min(end, buffer.count)
        guard start >= 0, start < end, let base = buffer.baseAddress else { return Swift.max(start, Swift.max(end, 0)) }
        // SAFETY: `0 <= start < end <= buffer.count`, so `base + start` is valid for `end - start` bytes.
        let found = unsafe kernel(base + start, end - start)
        return start + found
    }
}

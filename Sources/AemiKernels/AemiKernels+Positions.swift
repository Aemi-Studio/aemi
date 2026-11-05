//
//  AemiKernels+Positions.swift
//  AemiKernels
//
//  Every position of either of two bytes, in one pass, written in bulk (`adf_positions_of_either`, ADR 0031): line starts, field
//  separators. The kernel writes into room the caller gives and says how far it got, so it never writes out of bounds and never
//  needs an output as large as the input.
//

internal import CAemiKernels

extension AemiKernels {
    /// Writes `base + i` to `out` for each `i` in `0 ..< count` with `bytes[i] == a || bytes[i] == b`, in order, at most `capacity`
    /// of them; returns how many it wrote and the length of the prefix whose every hit was written (`count` unless `out` filled).
    ///
    /// Owner/bounds: the caller owns `bytes[0 ..< count]` for reading and `out[0 ..< capacity]` for writing, for the call, and keeps
    /// `base + count` below 2^32. `.scalar` forces the reference loop.
    // swiftlint:disable:next function_parameter_count
    public static func positions(
        ofEither a: UInt8,
        _ b: UInt8,
        base bytes: UnsafePointer<UInt8>,
        count: Int,
        offset base: UInt32,
        into out: UnsafeMutablePointer<UInt32>,
        capacity: Int,
        backend: Backend = .fastest
    ) -> (written: Int, consumed: Int) {
        guard count > 0, capacity > 0 else { return (0, count > 0 ? 0 : count) }
        var consumed = 0
        let written =
            if case .scalar = backend {
                unsafe adf_positions_of_either_scalar(bytes, count, a, b, base, out, capacity, &consumed)
            } else {
                unsafe adf_positions_of_either(bytes, count, a, b, base, out, capacity, &consumed)
            }
        return (written, consumed)
    }

    /// Appends to `positions` the index of every byte of `bytes[start ..< end]` equal to `a` or `b`, in order. Indices are of
    /// `bytes`; `bytes.count` must stay below 2^32.
    public static func appendPositions(
        ofEither a: UInt8,
        _ b: UInt8,
        in bytes: [UInt8],
        from start: Int = 0,
        to end: Int = .max,
        into positions: inout [UInt32],
        backend: Backend = .fastest
    ) {
        let end = Swift.min(end, bytes.count)
        guard start >= 0, start < end else { return }
        precondition(end <= Int(UInt32.max), "positions are 32-bit")
        bytes.withUnsafeBufferPointer { buffer in
            guard let source = buffer.baseAddress else { return }
            var at = start
            while at < end {
                // Room for a hit every 16 bytes of what is left, at least 64, grown when a dense input fills it.
                let room = Swift.max(64, (end - at) / 16)
                let before = positions.count
                positions.append(contentsOf: repeatElement(0, count: room))
                let (written, consumed) = positions.withUnsafeMutableBufferPointer { output -> (Int, Int) in
                    // SAFETY: `output` holds `before + room` elements, so `before ..< before + room` is the room given; the input
                    // range `at ..< end` is inside `bytes`.
                    guard let target = output.baseAddress else { return (0, end - at) }
                    return unsafe Self.positions(
                        ofEither: a,
                        b,
                        base: source + at,
                        count: end - at,
                        offset: UInt32(at),
                        into: target + before,
                        capacity: room,
                        backend: backend
                    )
                }
                positions.removeLast(room - written)
                at += consumed
            }
        }
    }
}

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Bytes placed flush against a page the process may not touch, so a kernel that reads one byte past the end (or, with
/// `.start`, one before the start) crashes instead of reading a neighbour's memory, which no comparison of results can show.
/// Promoted from MacFS's guard-page tests (aemi ADR 0021).
public enum GuardedBytes {
    /// Which edge of the bytes lies against the inaccessible page.
    public enum Edge: Sendable, CaseIterable {
        /// The last byte is the last readable one: overreads crash.
        case end
        /// The first byte is the first readable one: reads before the start crash.
        case start
    }

    /// Runs `body` with a copy of `bytes` against an inaccessible page at `edge`. The pointer is valid, and writable, for
    /// `bytes.count` bytes during `body` only.
    public static func with<Result>(
        _ bytes: [UInt8], against edge: Edge = .end, _ body: (UnsafeMutablePointer<UInt8>) throws -> Result
    ) rethrows -> Result {
        // [guard | data pages | guard]: both guards PROT_NONE, the bytes flush against the one `edge` names.
        let page = Int(getpagesize())
        let dataPages = max(1, (bytes.count + page - 1) / page)
        let length = (dataPages + 2) * page
        guard let mapping = mmap(nil, length, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0),
            mapping != MAP_FAILED
        else { preconditionFailure("GuardedBytes: mmap of \(length) bytes failed (errno \(errno))") }
        defer { munmap(mapping, length) }
        let pages = mapping.assumingMemoryBound(to: UInt8.self)
        precondition(mprotect(pages, page, PROT_NONE) == 0, "GuardedBytes: mprotect failed")
        precondition(mprotect(pages + (dataPages + 1) * page, page, PROT_NONE) == 0, "GuardedBytes: mprotect failed")
        let base = edge == .start ? pages + page : pages + (dataPages + 1) * page - bytes.count
        bytes.withUnsafeBufferPointer { source in
            if let from = source.baseAddress { base.update(from: from, count: source.count) }
        }
        return try body(base)
    }
}

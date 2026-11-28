/// Hands out contiguous regions of a fixed-size buffer front to back, wrapping around, and takes them
/// back in the order they were handed out — a staging ring for memory a consumer frees in submission
/// order (a GPU's command buffers, a DMA engine, a socket's send queue).
///
/// Only offsets: the memory itself (an `MTLBuffer`, a mapped file, a raw allocation) is the caller's.
/// A region never straddles the end; when it does not fit there, the tail is skipped and the region
/// starts at 0, the skipped bytes freed together with it.
public struct RegionRing: Sendable {
    /// A handed-out region: `offset ..< offset + count` of the buffer.
    public struct Region: Sendable, Equatable {
        public let offset: Int
        public let count: Int
        /// Increases by one per region; ``RegionRing/release(through:)`` takes it.
        public let id: UInt64
    }

    /// The bytes a live region holds back: its own, plus the end of the buffer it skipped.
    @usableFromInline
    struct Footprint: Sendable {
        @usableFromInline let start: Int
        @usableFromInline let count: Int
        @usableFromInline let id: UInt64

        @inlinable
        init(start: Int, count: Int, id: UInt64) {
            self.start = start
            self.count = count
            self.id = id
        }
    }

    public let capacity: Int
    /// Every region's offset and length is a multiple of this.
    public let alignment: Int
    @usableFromInline var live = RingQueue<Footprint>()
    /// Where the next region starts when it fits before the end.
    @usableFromInline var writeOffset = 0
    /// Bytes held back by live regions, skipped tails included.
    public private(set) var usedBytes = 0
    @usableFromInline var nextID: UInt64 = 0

    /// - Parameters:
    ///   - capacity: the buffer's size in bytes.
    ///   - alignment: a power of two every region's offset and size is rounded to.
    public init(capacity: Int, alignment: Int = 64) {
        precondition(alignment > 0 && alignment & (alignment - 1) == 0, "alignment must be a power of two")
        self.alignment = alignment
        self.capacity = capacity & ~(alignment - 1)
    }

    /// Live regions.
    @inlinable public var count: Int { live.count }

    @inlinable public var isEmpty: Bool { live.isEmpty }

    /// A region of at least `size` bytes, or `nil` when it does not fit until older regions are released.
    public mutating func allocate(_ size: Int) -> Region? {
        let length = (max(size, 1) + alignment - 1) & ~(alignment - 1)
        guard length <= capacity else { return nil }
        guard let oldest = live.first?.start else {
            // Empty: start at 0, so the whole buffer is one free run.
            writeOffset = 0
            return place(at: 0, length: length, footprintStart: 0)
        }
        if writeOffset > oldest {
            // Free runs: [writeOffset, capacity) then [0, oldest).
            if capacity - writeOffset >= length {
                return place(at: writeOffset, length: length, footprintStart: writeOffset)
            }
            guard length <= oldest else { return nil }
            return place(at: 0, length: length, footprintStart: writeOffset)
        }
        // Wrapped behind the oldest region: one free run [writeOffset, oldest).
        guard oldest - writeOffset >= length else { return nil }
        return place(at: writeOffset, length: length, footprintStart: writeOffset)
    }

    /// Records a region at `offset`; its footprint runs from `footprintStart` (an earlier offset when
    /// the region wrapped, covering the skipped tail) to its end.
    private mutating func place(at offset: Int, length: Int, footprintStart: Int) -> Region {
        let footprint = offset >= footprintStart ? offset + length - footprintStart : capacity - footprintStart + length
        let id = nextID
        nextID &+= 1
        live.append(Footprint(start: footprintStart, count: footprint, id: id))
        usedBytes += footprint
        writeOffset = offset + length
        return Region(offset: offset, count: length, id: id)
    }

    /// Releases the oldest live region; returns whether there was one.
    @discardableResult
    public mutating func releaseOldest() -> Bool {
        guard let footprint = live.popFirst() else { return false }
        usedBytes -= footprint.count
        if live.isEmpty { writeOffset = 0 }
        return true
    }

    /// Releases every live region up to and including `id` (regions complete in order).
    public mutating func release(through id: UInt64) {
        while let oldest = live.first, oldest.id <= id { releaseOldest() }
    }
}

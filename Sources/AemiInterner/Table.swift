#if canImport(Darwin)
    internal import Darwin
#elseif canImport(Glibc)
    internal import Glibc
#endif

/// Key bytes in chunks that never move, freed when the last table that points into them goes (ADR 0019). A table and
/// the tables frozen or merged from it share their arenas instead of copying bytes.
@safe final class Arena: @unchecked Sendable {
    static let chunkSize = 1 << 16
    /// A key at least this long gets a chunk of its own, so it does not strand the rest of the current one.
    static let ownChunkThreshold = chunkSize / 4

    private var chunks: [UnsafeMutableRawPointer] = unsafe []
    private var cursor: UnsafeMutableRawPointer?
    private var room = 0

    init(byteCapacity: Int) {
        if byteCapacity > 0 { startChunk(max(Self.chunkSize, byteCapacity)) }
    }

    deinit {
        for unsafe chunk in unsafe chunks { unsafe chunk.deallocate() }
    }

    /// A copy of `bytes` that stays where it is for the arena's life; nil for no bytes.
    func store(_ bytes: UnsafeRawBufferPointer) -> UnsafeRawPointer? {
        let count = bytes.count
        guard count > 0, let source = bytes.baseAddress else { return nil }
        let destination: UnsafeMutableRawPointer
        if count >= Self.ownChunkThreshold {
            unsafe destination = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 8)
            unsafe chunks.append(destination)
        } else {
            if count > room { startChunk(Self.chunkSize) }
            guard let current = unsafe cursor else { preconditionFailure("a chunk was just started") }
            unsafe destination = current
            unsafe cursor = unsafe current + count
            room -= count
        }
        unsafe destination.copyMemory(from: source, byteCount: count)
        return UnsafeRawPointer(destination)
    }

    private func startChunk(_ size: Int) {
        let chunk = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
        unsafe chunks.append(chunk)
        unsafe cursor = chunk
        room = size
    }
}

/// The symbol table behind ``Interner`` and ``FrozenInterner``: each symbol's bytes, length and hash, and an
/// open-addressing table of 64-bit slots holding the hash's top 32 bits beside symbol + 1 (0 marks an empty slot), so
/// bytes are compared only when 32 bits of hash agree. It doubles past three quarters full, rehashing from the stored
/// hashes.
@safe final class Table: @unchecked Sendable {
    static let tagMask: UInt64 = 0xFFFF_FFFF_0000_0000
    /// Symbol + 1 must fit the slot's low 32 bits.
    static let maximumCount = Int(UInt32.max) - 1

    private(set) var arenas: [Arena]
    private(set) var starts: ContiguousArray<UnsafeRawPointer?>
    private(set) var lengths: ContiguousArray<UInt32>
    private(set) var hashes: ContiguousArray<UInt64>
    private var slots: UnsafeMutablePointer<UInt64>
    private var mask: Int

    init(capacity: Int, arenas: [Arena]) {
        self.arenas = arenas
        unsafe starts = []
        lengths = []
        hashes = []
        unsafe starts.reserveCapacity(capacity)
        lengths.reserveCapacity(capacity)
        hashes.reserveCapacity(capacity)
        let size = Self.slotCount(for: capacity)
        unsafe slots = UnsafeMutablePointer<UInt64>.allocate(capacity: size)
        unsafe slots.initialize(repeating: 0, count: size)
        mask = size - 1
    }

    /// A table over keys known to be distinct, in symbol order: no bytes are compared.
    init(
        arenas: [Arena], starts: ContiguousArray<UnsafeRawPointer?>, lengths: ContiguousArray<UInt32>,
        hashes: ContiguousArray<UInt64>
    ) {
        self.arenas = arenas
        unsafe self.starts = starts
        self.lengths = lengths
        self.hashes = hashes
        let size = Self.slotCount(for: hashes.count)
        unsafe slots = UnsafeMutablePointer<UInt64>.allocate(capacity: size)
        unsafe slots.initialize(repeating: 0, count: size)
        mask = size - 1
        placeAll()
    }

    deinit { unsafe slots.deallocate() }

    var count: Int { lengths.count }

    /// The smallest power of two, at least 16, that holds `capacity` keys at most three quarters full.
    static func slotCount(for capacity: Int) -> Int {
        var size = 16
        while size / 4 * 3 < capacity { size <<= 1 }
        return size
    }

    /// The symbol of `key`, or the empty slot where it would go.
    @inline(__always)
    func find(_ key: UnsafeRawBufferPointer, hash: UInt64) -> (symbol: Int?, slot: Int) {
        let tag = hash & Self.tagMask
        var index = Int(truncatingIfNeeded: hash) & mask
        while true {
            let slot = unsafe slots[index]
            if slot == 0 { return (nil, index) }
            if slot & Self.tagMask == tag {
                let symbol = Int(truncatingIfNeeded: slot & 0xFFFF_FFFF) - 1
                if unsafe Int(lengths[symbol]) == key.count && equal(symbol, key) { return (symbol, index) }
            }
            index = (index + 1) & mask
        }
    }

    /// Adds a key, stored at `start`, in the empty `slot` that ``find(_:hash:)`` returned; its symbol.
    func insert(start: UnsafeRawPointer?, length: Int, hash: UInt64, at slot: Int) -> Int {
        let symbol = count
        precondition(symbol < Self.maximumCount, "an interner holds at most \(Self.maximumCount) keys")
        unsafe starts.append(start)
        lengths.append(UInt32(truncatingIfNeeded: length))
        hashes.append(hash)
        unsafe slots[slot] = (hash & Self.tagMask) | UInt64(symbol + 1)
        if count > (mask + 1) / 4 * 3 { grow() }
        return symbol
    }

    /// `symbol`'s bytes, valid while an arena of this table lives.
    @inline(__always)
    func bytes(of symbol: Int) -> UnsafeRawBufferPointer {
        unsafe UnsafeRawBufferPointer(start: starts[symbol], count: Int(lengths[symbol]))
    }

    /// A table that will not see this one's later keys; the bytes are shared.
    func copy() -> Table {
        unsafe Table(arenas: arenas, starts: starts, lengths: lengths, hashes: hashes)
    }

    private func equal(_ symbol: Int, _ key: UnsafeRawBufferPointer) -> Bool {
        guard key.count > 0 else { return true }
        guard let stored = unsafe starts[symbol], let base = key.baseAddress else { return false }
        return unsafe memcmp(stored, base, key.count) == 0
    }

    private func grow() {
        let size = (mask + 1) * 2
        unsafe slots.deallocate()
        unsafe slots = UnsafeMutablePointer<UInt64>.allocate(capacity: size)
        unsafe slots.initialize(repeating: 0, count: size)
        mask = size - 1
        placeAll()
    }

    /// Places every symbol by its stored hash; the slots must be empty.
    private func placeAll() {
        for symbol in 0 ..< hashes.count {
            let hash = hashes[symbol]
            var index = Int(truncatingIfNeeded: hash) & mask
            while unsafe slots[index] != 0 { index = (index + 1) & mask }
            unsafe slots[index] = (hash & Self.tagMask) | UInt64(symbol + 1)
        }
    }
}

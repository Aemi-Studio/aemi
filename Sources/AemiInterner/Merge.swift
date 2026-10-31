internal import Dispatch

#if canImport(Darwin)
    internal import Darwin
#elseif canImport(Glibc)
    internal import Glibc
#endif

/// A buffer several workers write at distinct indices, allocated and freed by one owner. The pointer never leaves it.
@safe struct SharedBuffer<Element>: @unchecked Sendable {
    private let base: UnsafeMutablePointer<Element>
    private let owned: Bool
    let count: Int

    init(repeating value: Element, count: Int) {
        self.count = count
        owned = true
        unsafe base = UnsafeMutablePointer<Element>.allocate(capacity: max(1, count))
        unsafe base.initialize(repeating: value, count: count)
    }

    /// A view of memory someone else owns, for the duration of their `withUnsafeMutableBufferPointer`.
    init(wrapping buffer: UnsafeMutableBufferPointer<Element>) {
        count = buffer.count
        owned = false
        unsafe base = unsafe buffer.baseAddress ?? UnsafeMutablePointer<Element>.allocate(capacity: 1)
    }

    subscript(index: Int) -> Element {
        get {
            precondition(index >= 0 && index < count)
            return unsafe base[index]
        }
        nonmutating set {
            precondition(index >= 0 && index < count)
            unsafe base[index] = newValue
        }
    }

    func array() -> ContiguousArray<Element> {
        unsafe ContiguousArray(UnsafeBufferPointer(start: base, count: count))
    }

    func free() {
        guard owned else { return }
        unsafe base.deinitialize(count: count)
        unsafe base.deallocate()
    }
}

/// ``Interner/merge(_:workers:)`` (ADR 0019): per-input tables merged shard by shard, the owner of each key being the
/// first input to hold it, at its local symbol; symbols are then numbered by (input, local symbol), which is
/// first-occurrence order over the inputs read in turn.
enum Merge {
    static let shardBits = 6
    static let shardCount = 1 << shardBits

    /// Six bits of the hash that neither the slot index (low bits) of a small table nor the tag (top 32) is made of.
    @inline(__always) static func shard(_ hash: UInt64) -> Int {
        Int(truncatingIfNeeded: (hash >> 26) & UInt64(shardCount - 1))
    }

    /// Runs `body` for every index in `0..<count`, spread over `workers` threads, and returns when all are done.
    static func parallel(_ count: Int, workers: Int, _ body: (Int) -> Void) {
        let lanes = max(1, min(workers, count))
        if lanes == 1 {
            for index in 0 ..< count { body(index) }
            return
        }
        // Swift 6.3's concurrentPerform takes a @Sendable closure; `body` runs only until it returns, on lanes that touch disjoint
        // indices, which is what the callers' shared buffers rely on already.
        nonisolated(unsafe) let body = body
        DispatchQueue.concurrentPerform(iterations: lanes) { lane in
            for index in stride(from: lane, to: count, by: lanes) { unsafe body(index) }
        }
    }

    static func run(_ inputs: [Table], workers: Int) -> MergedInterner {
        let workers = max(1, workers)
        // 1. Each input's symbols, by shard, in local order.
        var buckets = [[[UInt32]]](repeating: [], count: inputs.count)
        buckets.withUnsafeMutableBufferPointer { buckets in
            let shared = unsafe SharedBuffer<[[UInt32]]>(wrapping: buckets)
            parallel(inputs.count, workers: workers) { input in
                var byShard = [[UInt32]](repeating: [], count: shardCount)
                for symbol in 0 ..< inputs[input].count {
                    byShard[shard(inputs[input].hashes[symbol])].append(UInt32(truncatingIfNeeded: symbol))
                }
                shared[input] = byShard
            }
        }
        // 2. Each shard, inputs in order: the owner (input, local) of every local symbol.
        let ownerInput = inputs.map { SharedBuffer<UInt32>(repeating: 0, count: $0.count) }
        let ownerLocal = inputs.map { SharedBuffer<UInt32>(repeating: 0, count: $0.count) }
        defer {
            for buffer in ownerInput + ownerLocal { buffer.free() }
        }
        parallel(shardCount, workers: workers) { shard in
            findOwners(
                shard: shard, inputs: inputs, buckets: buckets, ownerInput: ownerInput, ownerLocal: ownerLocal)
        }
        // 3. Number the owned keys input by input, then point every other local symbol at its owner's number.
        let globals = inputs.map { SharedBuffer<UInt32>(repeating: 0, count: $0.count) }
        defer {
            for buffer in globals { buffer.free() }
        }
        let ownedCounts = SharedBuffer<Int>(repeating: 0, count: inputs.count)
        defer { ownedCounts.free() }
        parallel(inputs.count, workers: workers) { input in
            var owned = 0
            for local in 0 ..< inputs[input].count where ownerInput[input][local] == UInt32(input) {
                globals[input][local] = UInt32(truncatingIfNeeded: owned)
                owned += 1
            }
            ownedCounts[input] = owned
        }
        var bases = [Int](repeating: 0, count: inputs.count + 1)
        for input in inputs.indices { bases[input + 1] = bases[input] + ownedCounts[input] }
        let total = bases[inputs.count]
        precondition(total < Table.maximumCount, "an interner holds at most \(Table.maximumCount) keys")
        let starts = unsafe SharedBuffer<UnsafeRawPointer?>(repeating: nil, count: total)
        let lengths = SharedBuffer<UInt32>(repeating: 0, count: total)
        let hashes = SharedBuffer<UInt64>(repeating: 0, count: total)
        defer {
            unsafe starts.free()
            lengths.free()
            hashes.free()
        }
        parallel(inputs.count, workers: workers) { input in
            let table = inputs[input]
            let base = UInt32(truncatingIfNeeded: bases[input])
            for local in 0 ..< table.count where ownerInput[input][local] == UInt32(input) {
                let global = globals[input][local] + base
                globals[input][local] = global
                unsafe starts[Int(global)] = table.starts[local]
                lengths[Int(global)] = table.lengths[local]
                hashes[Int(global)] = table.hashes[local]
            }
        }
        parallel(inputs.count, workers: workers) { input in
            for local in 0 ..< inputs[input].count where ownerInput[input][local] != UInt32(input) {
                let owner = Int(ownerInput[input][local])
                globals[input][local] = globals[owner][Int(ownerLocal[input][local])]
            }
        }
        // 4. The merged table, over every input's arenas, and each input's remap.
        let merged = unsafe Table(
            arenas: inputs.flatMap(\.arenas), starts: starts.array(), lengths: lengths.array(), hashes: hashes.array())
        let remaps: [[Symbol]] = inputs.indices.map { input in
            (0 ..< inputs[input].count).map { Symbol(rawValue: globals[input][$0]) }
        }
        return MergedInterner(interner: FrozenInterner(table: merged), remaps: remaps)
    }

    /// The owners of the keys of one shard: an open-addressing table of the keys seen so far, each with the first
    /// (input, local) that held it.
    private static func findOwners(
        shard: Int, inputs: [Table], buckets: [[[UInt32]]], ownerInput: [SharedBuffer<UInt32>],
        ownerLocal: [SharedBuffer<UInt32>]
    ) {
        var size = 0
        for input in inputs.indices { size += buckets[input][shard].count }
        let slotCount = Table.slotCount(for: size)
        let mask = slotCount - 1
        var slots = [UInt64](repeating: 0, count: slotCount)
        var owners: [(input: UInt32, local: UInt32)] = []
        owners.reserveCapacity(size)
        for input in inputs.indices {
            let table = inputs[input]
            for local in buckets[input][shard] {
                let hash = table.hashes[Int(local)]
                let key = unsafe table.bytes(of: Int(local))
                let tag = hash & Table.tagMask
                var index = Int(truncatingIfNeeded: hash) & mask
                var owner: (input: UInt32, local: UInt32)?
                while slots[index] != 0 {
                    let slot = slots[index]
                    if slot & Table.tagMask == tag {
                        let candidate = owners[Int(slot & 0xFFFF_FFFF) - 1]
                        let other = unsafe inputs[Int(candidate.input)].bytes(of: Int(candidate.local))
                        if unsafe same(other, key) {
                            owner = candidate
                            break
                        }
                    }
                    index = (index + 1) & mask
                }
                let found = owner ?? (UInt32(truncatingIfNeeded: input), local)
                if owner == nil {
                    owners.append(found)
                    slots[index] = tag | UInt64(owners.count)
                }
                ownerInput[input][Int(local)] = found.input
                ownerLocal[input][Int(local)] = found.local
            }
        }
    }

    private static func same(_ a: UnsafeRawBufferPointer, _ b: UnsafeRawBufferPointer) -> Bool {
        guard a.count == b.count else { return false }
        guard a.count > 0, let left = a.baseAddress, let right = b.baseAddress else { return true }
        return unsafe memcmp(left, right, a.count) == 0
    }
}

/// ``Interner/serialized()``'s form read back far enough to know its size: each key's length and where the keys start.
struct SerializedLayout {
    let lengths: [Int]
    let keysStart: Int
    let keyBytes: Int

    init(_ bytes: [UInt8]) throws(InternerFormatError) {
        var offset = 0
        let count = try Self.varint(bytes, &offset)
        // Every length takes at least one byte, which bounds the count before anything is reserved for it.
        guard count <= bytes.count - offset else { throw .truncated }
        var lengths: [Int] = []
        lengths.reserveCapacity(count)
        var total = 0
        for _ in 0 ..< count {
            let length = try Self.varint(bytes, &offset)
            guard length <= bytes.count else { throw .truncated }
            lengths.append(length)
            total += length
        }
        guard total <= bytes.count - offset else { throw .truncated }
        guard total == bytes.count - offset else { throw .trailingBytes }
        self.lengths = lengths
        keysStart = offset
        keyBytes = total
    }

    /// A LEB128 varint of at most nine bytes (63 bits), advancing `offset`.
    private static func varint(_ bytes: [UInt8], _ offset: inout Int) throws(InternerFormatError) -> Int {
        var value = 0
        var shift = 0
        while true {
            guard offset < bytes.count, shift < 63 else { throw .truncated }
            let byte = bytes[offset]
            offset += 1
            value |= Int(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
    }
}

extension Table {
    func serialized() -> [UInt8] {
        var out: [UInt8] = []
        var keyBytes = 0
        for length in lengths { keyBytes += Int(length) }
        out.reserveCapacity(keyBytes + (count + 1) * 2)
        Self.appendVarint(count, to: &out)
        for length in lengths { Self.appendVarint(Int(length), to: &out) }
        for symbol in 0 ..< count { unsafe out.append(contentsOf: bytes(of: symbol)) }
        return out
    }

    private static func appendVarint(_ value: Int, to out: inout [UInt8]) {
        var rest = value
        while rest >= 0x80 {
            out.append(UInt8(truncatingIfNeeded: rest) | 0x80)
            rest >>= 7
        }
        out.append(UInt8(rest))
    }
}

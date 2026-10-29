// Interner probe for AemiInterner (analyzerkit roadmap 0015, ADR-0012 there). Not part of the package build.
//   swiftc -O -wmo Benchmarks/Interner/intern-probe.swift Sources/AemiKernel/XXH64.swift -o /tmp/intern-probe
//   /tmp/intern-probe <usrs.txt> <tokens.txt>
// Each input holds one key per line, in the order a tool meets them; an empty line ends a file. The USR stream is
// maintastic's index store read file by file (deadwood's workload), the token stream its Swift files tokenized by
// SwiftParser (dolly's). Prints the median of five runs of each variant, and checks every variant against the
// sequential interner.
import Darwin
import Dispatch

// MARK: - Workload

struct Workload {
    let name: String
    let base: UnsafeMutableRawPointer
    let starts: [Int]
    let lengths: [Int]
    /// Occurrence index where each file begins.
    let files: [Int]

    var count: Int { starts.count }

    static func load(_ path: String, name: String, filesOf size: Int?) -> Workload {
        let descriptor = open(path, O_RDONLY)
        precondition(descriptor >= 0, "open \(path)")
        var status = stat()
        fstat(descriptor, &status)
        let length = Int(status.st_size)
        let base = UnsafeMutableRawPointer.allocate(byteCount: length + 8, alignment: 16)
        var read = 0
        while read < length { read += Darwin.read(descriptor, base + read, length - read) }
        close(descriptor)
        var starts: [Int] = []
        var lengths: [Int] = []
        var files: [Int] = [0]
        var lineStart = 0
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        for index in 0 ..< length where bytes[index] == 0x0A {
            let n = index - lineStart
            if n == 0 {
                if files.last != starts.count { files.append(starts.count) }
            } else {
                starts.append(lineStart)
                lengths.append(n)
                if let size, starts.count % size == 0 { files.append(starts.count) }
            }
            lineStart = index + 1
        }
        if files.last == starts.count { files.removeLast() }
        return Workload(name: name, base: base, starts: starts, lengths: lengths, files: files)
    }

    @inline(__always) func pointer(_ index: Int) -> UnsafeRawPointer { UnsafeRawPointer(base + starts[index]) }

    /// `parts` contiguous ranges of occurrences, split at file boundaries, of about equal size.
    func ranges(_ parts: Int) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var lower = 0
        var fileIndex = 0
        for part in 1 ... parts {
            let target = count * part / parts
            while fileIndex < files.count && files[fileIndex] < target { fileIndex += 1 }
            let upper = part == parts ? count : (fileIndex < files.count ? files[fileIndex] : count)
            result.append(lower ..< max(lower, upper))
            lower = max(lower, upper)
        }
        return result
    }
}

// MARK: - Hashes

protocol ByteHash { static func hash(_ p: UnsafeRawPointer, _ n: Int) -> UInt64 }

enum XXH: ByteHash {
    @inline(__always) static func hash(_ p: UnsafeRawPointer, _ n: Int) -> UInt64 {
        XXH64.hash(UnsafeRawBufferPointer(start: p, count: n))
    }
}

@inline(__always) func r8(_ p: UnsafeRawPointer, _ at: Int) -> UInt64 {
    p.loadUnaligned(fromByteOffset: at, as: UInt64.self)
}
@inline(__always) func r4(_ p: UnsafeRawPointer, _ at: Int) -> UInt64 {
    UInt64(p.loadUnaligned(fromByteOffset: at, as: UInt32.self))
}
@inline(__always) func mum(_ a: UInt64, _ b: UInt64) -> (UInt64, UInt64) {
    let r = a.multipliedFullWidth(by: b)
    return (r.low, r.high)
}
@inline(__always) func mix(_ a: UInt64, _ b: UInt64) -> UInt64 {
    let (lo, hi) = mum(a, b)
    return lo ^ hi
}

/// wyhash (final 4.2, default secret), the short-key hash Go, Zig and rapidhash build on. Checked against the reference
/// `wyhash.h`: its seven test vectors (seed = index) and lengths 3 to 150 with seed 0 (diary 2026-10-29-03).
enum Wy: ByteHash {
    static let s0: UInt64 = 0x2d35_8dcc_aa6c_78a5, s1: UInt64 = 0x8bb8_4b93_962e_acc9
    static let s2: UInt64 = 0x4b33_a62e_d433_d4a3, s3: UInt64 = 0x4d5a_2da5_1de1_aa47

    @inline(__always) static func hash(_ p: UnsafeRawPointer, _ n: Int) -> UInt64 {
        var seed = mix(s0, s1)  // wyhash: seed ^= wymix(seed ^ s0, s1), with seed 0
        var a: UInt64 = 0
        var b: UInt64 = 0
        if n <= 16 {
            if n >= 4 {
                let shift = (n >> 3) << 2
                a = (r4(p, 0) << 32) | r4(p, shift)
                b = (r4(p, n - 4) << 32) | r4(p, n - 4 - shift)
            } else if n > 0 {
                let bytes = p.assumingMemoryBound(to: UInt8.self)
                a = (UInt64(bytes[0]) << 16) | (UInt64(bytes[n >> 1]) << 8) | UInt64(bytes[n - 1])
            }
        } else {
            var i = n
            var q = p
            if i >= 48 {
                var see1 = seed
                var see2 = seed
                repeat {
                    seed = mix(r8(q, 0) ^ s1, r8(q, 8) ^ seed)
                    see1 = mix(r8(q, 16) ^ s2, r8(q, 24) ^ see1)
                    see2 = mix(r8(q, 32) ^ s3, r8(q, 40) ^ see2)
                    q += 48
                    i -= 48
                } while i >= 48
                seed ^= see1 ^ see2
            }
            while i > 16 {
                seed = mix(r8(q, 0) ^ s1, r8(q, 8) ^ seed)
                i -= 16
                q += 16
            }
            a = r8(q, i - 16)
            b = r8(q, i - 8)
        }
        a ^= s1
        b ^= seed
        (a, b) = mum(a, b)
        return mix(a ^ s0 ^ UInt64(n), b ^ s1)
    }
}

/// rustc's FxHasher over 8-byte words, then murmur's finalizer so the low and high bits both mix.
enum Fx: ByteHash {
    @inline(__always) static func hash(_ p: UnsafeRawPointer, _ n: Int) -> UInt64 {
        let k: UInt64 = 0x517c_c1b7_2722_0a95
        var h = UInt64(n)
        var i = 0
        while i + 8 <= n {
            h = ((h << 5) | (h >> 59) ^ r8(p, i)) &* k
            i += 8
        }
        if i < n {
            var tail: UInt64 = 0
            let bytes = p.assumingMemoryBound(to: UInt8.self)
            for j in i ..< n { tail |= UInt64(bytes[j]) << (UInt64(j - i) * 8) }
            h = ((h << 5) | (h >> 59) ^ tail) &* k
        }
        h ^= h >> 33
        h &*= 0xff51_afd7_ed55_8ccd
        h ^= h >> 33
        h &*= 0xc4ce_b9fe_1a85_ec53
        return h ^ (h >> 33)
    }
}

/// The standard library's SipHash-1-3, as `[String: _]` uses (seeded per process).
enum Sip: ByteHash {
    @inline(__always) static func hash(_ p: UnsafeRawPointer, _ n: Int) -> UInt64 {
        var hasher = Hasher()
        hasher.combine(bytes: UnsafeRawBufferPointer(start: p, count: n))
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }
}

// MARK: - The arena interner

/// Bytes in 64 KiB chunks that never move; an open-addressing table of 64-bit slots, the hash's top 32 bits beside
/// symbol + 1, so a probe compares bytes only when 32 hash bits agree.
final class Interner<H: ByteHash> {
    static var chunkSize: Int { 1 << 16 }
    var chunks: [UnsafeMutableRawPointer] = []
    var cursor: UnsafeMutableRawPointer
    var room = 0
    var keys: [UnsafeRawPointer] = []
    var lengths: [UInt32] = []
    var hashes: [UInt64] = []
    var slots: UnsafeMutablePointer<UInt64>
    var mask: Int

    init(capacity: Int = 1024) {
        var size = 16
        while size < capacity * 2 { size <<= 1 }
        slots = .allocate(capacity: size)
        slots.initialize(repeating: 0, count: size)
        mask = size - 1
        cursor = UnsafeMutableRawPointer.allocate(byteCount: Self.chunkSize, alignment: 8)
        chunks.append(cursor)
        room = Self.chunkSize
    }

    deinit {
        for chunk in chunks { chunk.deallocate() }
        slots.deallocate()
    }

    var count: Int { keys.count }

    @inline(__always) func intern(_ p: UnsafeRawPointer, _ n: Int) -> UInt32 { intern(p, n, hash: H.hash(p, n)) }

    @inline(__always) func intern(_ p: UnsafeRawPointer, _ n: Int, hash h: UInt64) -> UInt32 {
        let tag = h & 0xFFFF_FFFF_0000_0000
        var i = Int(truncatingIfNeeded: h) & mask
        while true {
            let slot = slots[i]
            if slot == 0 { break }
            if slot & 0xFFFF_FFFF_0000_0000 == tag {
                let symbol = Int(truncatingIfNeeded: slot & 0xFFFF_FFFF) - 1
                if lengths[symbol] == UInt32(n) && memcmp(keys[symbol], p, n) == 0 { return UInt32(symbol) }
            }
            i = (i + 1) & mask
        }
        let symbol = keys.count
        keys.append(store(p, n))
        lengths.append(UInt32(n))
        hashes.append(h)
        slots[i] = tag | UInt64(symbol + 1)
        if keys.count * 4 > (mask + 1) * 3 { grow() }
        return UInt32(symbol)
    }

    @inline(__always) func lookup(_ p: UnsafeRawPointer, _ n: Int) -> UInt32? {
        let h = H.hash(p, n)
        let tag = h & 0xFFFF_FFFF_0000_0000
        var i = Int(truncatingIfNeeded: h) & mask
        while true {
            let slot = slots[i]
            if slot == 0 { return nil }
            if slot & 0xFFFF_FFFF_0000_0000 == tag {
                let symbol = Int(truncatingIfNeeded: slot & 0xFFFF_FFFF) - 1
                if lengths[symbol] == UInt32(n) && memcmp(keys[symbol], p, n) == 0 { return UInt32(symbol) }
            }
            i = (i + 1) & mask
        }
    }

    private func store(_ p: UnsafeRawPointer, _ n: Int) -> UnsafeRawPointer {
        if n > room {
            let size = max(Self.chunkSize, n)
            cursor = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
            chunks.append(cursor)
            room = size
        }
        cursor.copyMemory(from: p, byteCount: n)
        let stored = UnsafeRawPointer(cursor)
        cursor += n
        room -= n
        return stored
    }

    private func grow() {
        let size = (mask + 1) * 2
        slots.deallocate()
        slots = .allocate(capacity: size)
        slots.initialize(repeating: 0, count: size)
        mask = size - 1
        for symbol in 0 ..< keys.count {
            let h = hashes[symbol]
            var i = Int(truncatingIfNeeded: h) & mask
            while slots[i] != 0 { i = (i + 1) & mask }
            slots[i] = (h & 0xFFFF_FFFF_0000_0000) | UInt64(symbol + 1)
        }
    }
}

// MARK: - Parallel: per-worker interners merged by hash shard, deterministically

let shardBits = 6
let shardCount = 1 << shardBits
@inline(__always) func shard(_ h: UInt64) -> Int { Int(truncatingIfNeeded: (h >> 26) & UInt64(shardCount - 1)) }

/// A shard's table after the merge: the owner of each key (the first worker to meet it, at its local symbol).
final class ShardTable {
    var slots: [UInt64]
    var mask: Int
    var owners: [(worker: Int32, local: UInt32)] = []
    init(capacity: Int) {
        var size = 16
        while size < capacity * 2 { size <<= 1 }
        slots = Array(repeating: 0, count: size)
        mask = size - 1
    }
}

final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

/// Interns `workload` on `workers` threads: each interns a contiguous run of files into its own table, then the tables
/// merge shard by shard, and symbols are numbered in first-occurrence order — what one interner reading the whole input
/// in order would give. Returns the symbol of every occurrence.
func mergedIntern<H: ByteHash>(_ workload: Workload, workers: Int, _: H.Type) -> (symbols: [UInt32], distinct: Int) {
    let ranges = workload.ranges(workers)
    let locals = (0 ..< workers).map { _ in Box<Interner<H>?>(nil) }
    let localSymbols = (0 ..< workers).map { _ in Box<[UInt32]>([]) }
    let buckets = (0 ..< workers).map { _ in Box<[[UInt32]]>([]) }
    // 1. Each worker interns its files and buckets its symbols by shard.
    DispatchQueue.concurrentPerform(iterations: workers) { w in
        let interner = Interner<H>(capacity: 4096)
        var symbols: [UInt32] = []
        symbols.reserveCapacity(ranges[w].count)
        for index in ranges[w] { symbols.append(interner.intern(workload.pointer(index), workload.lengths[index])) }
        var byShard = Array(repeating: [UInt32](), count: shardCount)
        for symbol in 0 ..< interner.count { byShard[shard(interner.hashes[symbol])].append(UInt32(symbol)) }
        locals[w].value = interner
        localSymbols[w].value = symbols
        buckets[w].value = byShard
    }
    let interners = locals.map { $0.value! }
    // owner[w][local] = (worker, local) that owns the key. Each shard writes disjoint locals.
    let ownerWorker = interners.map { UnsafeMutablePointer<Int32>.allocate(capacity: max(1, $0.count)) }
    let ownerLocal = interners.map { UnsafeMutablePointer<UInt32>.allocate(capacity: max(1, $0.count)) }
    // 2. Each shard, in worker order, finds the first owner of each key.
    DispatchQueue.concurrentPerform(iterations: shardCount) { s in
        var size = 0
        for w in 0 ..< workers { size += buckets[w].value[s].count }
        let table = ShardTable(capacity: size)
        for w in 0 ..< workers {
            let interner = interners[w]
            for local in buckets[w].value[s] {
                let l = Int(local)
                let h = interner.hashes[l]
                let n = Int(interner.lengths[l])
                let p = interner.keys[l]
                let tag = h & 0xFFFF_FFFF_0000_0000
                var i = Int(truncatingIfNeeded: h) & table.mask
                var owner: (Int32, UInt32)?
                while true {
                    let slot = table.slots[i]
                    if slot == 0 { break }
                    if slot & 0xFFFF_FFFF_0000_0000 == tag {
                        let o = table.owners[Int(slot & 0xFFFF_FFFF) - 1]
                        let other = interners[Int(o.worker)]
                        if other.lengths[Int(o.local)] == UInt32(n) && memcmp(other.keys[Int(o.local)], p, n) == 0 {
                            owner = o
                            break
                        }
                    }
                    i = (i + 1) & table.mask
                }
                if owner == nil {
                    table.owners.append((Int32(w), local))
                    table.slots[i] = tag | UInt64(table.owners.count)
                    owner = (Int32(w), local)
                }
                ownerWorker[w][l] = owner!.0
                ownerLocal[w][l] = owner!.1
            }
        }
    }
    // 3. Number the owned keys: worker by worker, local order within a worker.
    var bases = [Int](repeating: 0, count: workers + 1)
    let globals = interners.map { UnsafeMutablePointer<UInt32>.allocate(capacity: max(1, $0.count)) }
    let ownedCounts = Box([Int](repeating: 0, count: workers))
    DispatchQueue.concurrentPerform(iterations: workers) { w in
        var owned = 0
        for l in 0 ..< interners[w].count where ownerWorker[w][l] == Int32(w) {
            globals[w][l] = UInt32(owned)  // rank, rebased below
            owned += 1
        }
        ownedCounts.value[w] = owned
    }
    for w in 0 ..< workers { bases[w + 1] = bases[w] + ownedCounts.value[w] }
    // 4. Rebase the owned, then point every other local at its owner's number, then remap the occurrences.
    DispatchQueue.concurrentPerform(iterations: workers) { w in
        for l in 0 ..< interners[w].count where ownerWorker[w][l] == Int32(w) { globals[w][l] += UInt32(bases[w]) }
    }
    DispatchQueue.concurrentPerform(iterations: workers) { w in
        for l in 0 ..< interners[w].count where ownerWorker[w][l] != Int32(w) {
            globals[w][l] = globals[Int(ownerWorker[w][l])][Int(ownerLocal[w][l])]
        }
    }
    let result = UnsafeMutablePointer<UInt32>.allocate(capacity: workload.count)
    DispatchQueue.concurrentPerform(iterations: workers) { w in
        var index = ranges[w].lowerBound
        for local in localSymbols[w].value {
            result[index] = globals[w][Int(local)]
            index += 1
        }
    }
    let symbols = Array(UnsafeBufferPointer(start: result, count: workload.count))
    result.deallocate()
    for pointer in ownerWorker { pointer.deallocate() }
    for pointer in ownerLocal { pointer.deallocate() }
    for pointer in globals { pointer.deallocate() }
    return (symbols, bases[workers])
}

/// Interns `workload` on `workers` threads into one table split in lock-striped shards. Symbols are shard-local
/// (shard in the top bits), so they depend on timing: a run must renumber to be deterministic (not timed here).
func stripedIntern<H: ByteHash>(_ workload: Workload, workers: Int, _: H.Type) -> (symbols: [UInt32], distinct: Int) {
    let ranges = workload.ranges(workers)
    let stripes = (0 ..< shardCount).map { _ in Interner<H>(capacity: 256) }
    let locks = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: shardCount)
    locks.initialize(repeating: os_unfair_lock(), count: shardCount)
    let result = UnsafeMutablePointer<UInt32>.allocate(capacity: workload.count)
    DispatchQueue.concurrentPerform(iterations: workers) { w in
        for index in ranges[w] {
            let p = workload.pointer(index)
            let n = workload.lengths[index]
            let h = H.hash(p, n)
            let s = shard(h)
            os_unfair_lock_lock(locks + s)
            let local = stripes[s].intern(p, n, hash: h)
            os_unfair_lock_unlock(locks + s)
            result[index] = UInt32(s) << 26 | local
        }
    }
    let symbols = Array(UnsafeBufferPointer(start: result, count: workload.count))
    result.deallocate()
    locks.deallocate()
    return (symbols, stripes.reduce(0) { $0 + $1.count })
}

// MARK: - Measurement

func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

func median(_ runs: Int = 5, _ body: () -> Void) -> Double {
    var times: [Double] = []
    for _ in 0 ..< runs {
        let start = now()
        body()
        times.append(Double(now() - start) / 1e6)
    }
    return times.sorted()[runs / 2]
}

func bytesInUse() -> Int {
    var statistics = malloc_statistics_t()
    malloc_zone_statistics(nil, &statistics)
    return statistics.size_in_use
}

func pad(_ text: String, _ width: Int) -> String { text + String(repeating: " ", count: max(0, width - text.count)) }
/// `value` with one decimal, right-aligned in `width`.
func fixed(_ value: Double, _ width: Int = 8) -> String {
    let tenths = Int((value * 10).rounded())
    let text = "\(tenths / 10).\(tenths % 10)"
    return String(repeating: " ", count: max(0, width - text.count)) + text
}
func ms(_ value: Double) -> String { fixed(value) + " ms" }

func run(_ workload: Workload) {
    let distinctBytes: Int = {
        let interner = Interner<Wy>()
        for index in 0 ..< workload.count { _ = interner.intern(workload.pointer(index), workload.lengths[index]) }
        return interner.lengths.reduce(0) { $0 + Int($1) }
    }()
    let reference = Interner<Wy>()
    var expected = [UInt32](repeating: 0, count: workload.count)
    for index in 0 ..< workload.count {
        expected[index] = reference.intern(workload.pointer(index), workload.lengths[index])
    }
    let distinct = reference.count
    let meanBytes: Double = Double(distinctBytes) / Double(distinct)
    let header: String = "\n== \(workload.name): \(workload.count) occurrences, \(distinct) distinct"
    print(header + ", \(workload.files.count) files, \(fixed(meanBytes, 0)) bytes per distinct key")

    // 1. Intern the whole stream, one thread.
    print("-- intern, one thread (median of 5)")
    var dictionaryResult: [UInt32] = []
    let fromBytes = median {
        var table: [String: UInt32] = [:]
        var result = [UInt32](repeating: 0, count: workload.count)
        for index in 0 ..< workload.count {
            let key = String(
                decoding: UnsafeRawBufferPointer(start: workload.pointer(index), count: workload.lengths[index]),
                as: UTF8.self)
            if let symbol = table[key] {
                result[index] = symbol
            } else {
                let symbol = UInt32(table.count)
                table[key] = symbol
                result[index] = symbol
            }
        }
        dictionaryResult = result
    }
    precondition(dictionaryResult == expected, "dictionary disagrees")
    print("\(pad("[String: UInt32], String made from the bytes", 52))\(ms(fromBytes))")
    let strings = (0 ..< workload.count)
        .map {
            String(
                decoding: UnsafeRawBufferPointer(start: workload.pointer($0), count: workload.lengths[$0]),
                as: UTF8.self)
        }
    let premade = median {
        var table: [String: UInt32] = [:]
        var result = [UInt32](repeating: 0, count: workload.count)
        for index in 0 ..< workload.count {
            if let symbol = table[strings[index]] {
                result[index] = symbol
            } else {
                let symbol = UInt32(table.count)
                table[strings[index]] = symbol
                result[index] = symbol
            }
        }
        dictionaryResult = result
    }
    precondition(dictionaryResult == expected)
    print("\(pad("[String: UInt32], String already made (not timed)", 52))\(ms(premade))")
    func arena<H: ByteHash>(_ name: String, _: H.Type) {
        var result: [UInt32] = []
        let time = median {
            let interner = Interner<H>()
            var symbols = [UInt32](repeating: 0, count: workload.count)
            for index in 0 ..< workload.count {
                symbols[index] = interner.intern(workload.pointer(index), workload.lengths[index])
            }
            result = symbols
        }
        precondition(result == expected, "\(name) disagrees")
        let hashOnly = median {
            var sum: UInt64 = 0
            for index in 0 ..< workload.count { sum &+= H.hash(workload.pointer(index), workload.lengths[index]) }
            if sum == 42 { print("") }
        }
        let interner = Interner<H>()
        for index in 0 ..< workload.count { _ = interner.intern(workload.pointer(index), workload.lengths[index]) }
        let lookups = median {
            var sum: UInt32 = 0
            for index in 0 ..< workload.count {
                sum &+= interner.lookup(workload.pointer(index), workload.lengths[index]) ?? 0
            }
            if sum == 42 { print("") }
        }
        let label: String = pad("arena, " + name, 52) + ms(time)
        print(label + "   (hashing alone \(ms(hashOnly)), lookups of every occurrence \(ms(lookups)))")
    }
    arena("XXH64 (AemiKernel)", XXH.self)
    arena("wyhash", Wy.self)
    arena("Fx words + fmix64", Fx.self)
    arena("SipHash-1-3 (stdlib Hasher)", Sip.self)

    // 2. Memory per distinct key, once built (malloc's bytes in use, before and after).
    print("-- memory per distinct key, built (key bytes average \(distinctBytes / distinct))")
    do {
        let before = bytesInUse()
        var table: [String: UInt32] = [:]
        var list: [String] = []
        for index in 0 ..< workload.count {
            let key = String(
                decoding: UnsafeRawBufferPointer(start: workload.pointer(index), count: workload.lengths[index]),
                as: UTF8.self)
            if table[key] == nil {
                table[key] = UInt32(list.count)
                list.append(key)
            }
        }
        let used = bytesInUse() - before
        print("\(pad("[String: UInt32] + [String] for symbol -> text", 52))\(fixed(Double(used) / Double(distinct))) B")
        withExtendedLifetime((table, list)) {}
    }
    do {
        let before = bytesInUse()
        let interner = Interner<Wy>()
        for index in 0 ..< workload.count { _ = interner.intern(workload.pointer(index), workload.lengths[index]) }
        let used = bytesInUse() - before
        print("\(pad("arena (bytes, pointer, length, hash, slot)", 52))\(fixed(Double(used) / Double(distinct))) B")
        withExtendedLifetime(interner) {}
    }

    // 3. Parallel.
    print("-- parallel intern of the stream, wyhash (median of 5)")
    for workers in [1, 2, 4, 8] {
        var merged: (symbols: [UInt32], distinct: Int) = ([], 0)
        let mergedTime = median { merged = mergedIntern(workload, workers: workers, Wy.self) }
        precondition(merged.symbols == expected, "merge with \(workers) workers is not the sequential numbering")
        var striped: (symbols: [UInt32], distinct: Int) = ([], 0)
        let stripedTime = median { striped = stripedIntern(workload, workers: workers, Wy.self) }
        precondition(striped.distinct == distinct)
        let line: String =
            "\(workers) worker(s): per-worker tables + sharded merge (deterministic) \(ms(mergedTime));  "
        print(line + "lock-striped table (not deterministic) \(ms(stripedTime))")
    }
}

@main enum Probe {
    static func main() {
        let arguments = CommandLine.arguments
        precondition(arguments.count == 3, "usage: intern-probe <usrs.txt> <tokens.txt>")
        // The USR dump has no file boundaries: maintastic averages 222 occurrences per file.
        run(Workload.load(arguments[1], name: "USRs (deadwood)", filesOf: 222))
        run(Workload.load(arguments[2], name: "tokens (dolly)", filesOf: nil))
    }
}

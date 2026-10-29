// Directory-walk probe for AemiFileSystem (analyzerkit roadmap 0006, ADR 0013 there). Not part of the package build.
//   swiftc -O Benchmarks/DirectoryWalk/walk-probe.swift -o /tmp/walk-probe && /tmp/walk-probe <root> [--shallow]
// Walks <root> the way SourceDiscovery does (skips .build, .git, DerivedData, .swiftpm, checkouts and hidden entries;
// links are counted, not followed) with each method, checks they agree, and prints median and spread of five runs.
import Darwin
import Foundation

let skipped: Set<String> = [".build", ".git", "DerivedData", ".swiftpm", "checkouts"]
func entered(_ name: String) -> Bool { !name.hasPrefix(".") && !skipped.contains(name) }

struct Counts: Equatable, CustomStringConvertible {
    var directories = 0, files = 0, swiftFiles = 0, links = 0, other = 0, stats = 0
    var description: String { "dirs \(directories) files \(files) swift \(swiftFiles) links \(links) other \(other)" }
    static func == (a: Counts, b: Counts) -> Bool {
        (a.directories, a.files, a.swiftFiles, a.links, a.other) == (
            b.directories, b.files, b.swiftFiles, b.links, b.other
        )
    }
    mutating func add(_ o: Counts) {
        directories += o.directories
        files += o.files
        swiftFiles += o.swiftFiles
        links += o.links
        other += o.other
        stats += o.stats
    }
}

enum Kind { case directory, file, link, other }

func count(_ name: String, _ kind: Kind, into c: inout Counts) -> Bool {
    switch kind {
        case .directory:
            c.directories += 1
            return true
        case .file:
            c.files += 1
            if name.hasSuffix(".swift") { c.swiftFiles += 1 }
        case .link: c.links += 1
        case .other: c.other += 1
    }
    return false
}

// A. Today's SourceDiscovery: FileManager listing and an attributes dictionary per entry.
func walkFoundation(_ root: String) -> Counts {
    var c = Counts()
    var stack = [root]
    let fm = FileManager.default
    while let dir = stack.popLast() {
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
        for name in names.sorted() where entered(name) {
            let path = dir + "/" + name
            c.stats += 1
            let type = (try? fm.attributesOfItem(atPath: path))?[.type] as? FileAttributeType
            let kind: Kind =
                type == .typeDirectory
                ? .directory
                : type == .typeRegular
                    ? .file
                    : type == .typeSymbolicLink ? .link : .other
            if count(name, kind, into: &c) { stack.append(path) }
        }
    }
    return c
}

func kind(dType: UInt8) -> Kind? {
    switch Int32(dType) {
        case DT_DIR: .directory
        case DT_REG: .file
        case DT_LNK: .link
        case DT_UNKNOWN: nil
        default: .other
    }
}

func kind(mode: mode_t) -> Kind {
    switch mode & S_IFMT {
        case S_IFDIR: .directory
        case S_IFREG: .file
        case S_IFLNK: .link
        default: .other
    }
}

func name(of entry: UnsafeMutablePointer<dirent>) -> String {
    withUnsafePointer(to: &entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: 1024) { String(cString: $0) }
    }
}

// B. readdir with d_type, by path; lstat only when the type is unknown.
func walkReaddirPath(_ root: String) -> Counts {
    var c = Counts()
    var stack = [root]
    while let dir = stack.popLast() {
        guard let handle = opendir(dir) else { continue }
        while let entry = readdir(handle) {
            let n = name(of: entry)
            guard n != ".", n != "..", entered(n) else { continue }
            let path = dir + "/" + n
            var k = kind(dType: entry.pointee.d_type)
            if k == nil {
                var s = stat()
                c.stats += 1
                k = lstat(path, &s) == 0 ? kind(mode: s.st_mode) : .other
            }
            if count(n, k!, into: &c) { stack.append(path) }
        }
        closedir(handle)
    }
    return c
}

// C. openat descent: each directory opened relative to its parent's descriptor, O_NOFOLLOW.
nonisolated(unsafe) var openDescriptors = 0
nonisolated(unsafe) var maximumDescriptors = 0
let descriptorLock = NSLock()
func opened() {
    descriptorLock.lock()
    openDescriptors += 1
    maximumDescriptors = max(maximumDescriptors, openDescriptors)
    descriptorLock.unlock()
}
func closed() {
    descriptorLock.lock()
    openDescriptors -= 1
    descriptorLock.unlock()
}

func walkOpenat(_ root: String) -> Counts {
    var c = Counts()
    func visit(_ fd: Int32) {
        guard let handle = fdopendir(fd) else {
            close(fd)
            closed()
            return
        }
        var children: [String] = []
        while let entry = readdir(handle) {
            let n = name(of: entry)
            guard n != ".", n != "..", entered(n) else { continue }
            var k = kind(dType: entry.pointee.d_type)
            if k == nil {
                var s = stat()
                c.stats += 1
                k = fstatat(dirfd(handle), n, &s, AT_SYMLINK_NOFOLLOW) == 0 ? kind(mode: s.st_mode) : .other
            }
            if count(n, k!, into: &c) { children.append(n) }
        }
        for child in children {
            let sub = openat(dirfd(handle), child, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if sub >= 0 {
                opened()
                visit(sub)
            }
        }
        closedir(handle)
        closed()
    }
    let fd = open(root, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    if fd >= 0 {
        opened()
        visit(fd)
    }
    return c
}

// D. getattrlistbulk: names and object types in bulk, one call per buffer of entries.
func listBulk(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ size: Int, _ body: (String, Kind) -> Void) {
    var request = attrlist()
    request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
    request.commonattr =
        attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME) | attrgroup_t(ATTR_CMN_OBJTYPE)
    while true {
        let n = getattrlistbulk(fd, &request, buffer, size, 0)
        if n <= 0 { return }
        var entry = buffer
        for _ in 0 ..< n {
            let length = Int(entry.loadUnaligned(as: UInt32.self))
            var field = entry + 4 + MemoryLayout<attribute_set_t>.size
            let reference = field.loadUnaligned(as: attrreference_t.self)
            let namePointer = (field + Int(reference.attr_dataoffset)).assumingMemoryBound(to: CChar.self)
            field += MemoryLayout<attrreference_t>.size
            let type = field.loadUnaligned(as: fsobj_type_t.self)
            let k: Kind =
                switch type { case UInt32(VDIR.rawValue): .directory case UInt32(VREG.rawValue): .file
                    case UInt32(VLNK.rawValue): .link
                    default: .other
                }
            body(String(cString: namePointer), k)
            entry += length
        }
    }
}

/// The getattrlistbulk buffer; `WALK_PROBE_BUFFER_KIB` overrides it.
let bulkSize = (ProcessInfo.processInfo.environment["WALK_PROBE_BUFFER_KIB"].flatMap(Int.init) ?? 128) * 1024
func walkBulk(_ root: String) -> Counts {
    var c = Counts()
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: bulkSize, alignment: 16)
    defer { buffer.deallocate() }
    func visit(_ fd: Int32) {
        var children: [String] = []
        listBulk(fd, buffer, bulkSize) { n, k in
            guard entered(n) else { return }
            if count(n, k, into: &c) { children.append(n) }
        }
        for child in children {
            let sub = openat(fd, child, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if sub >= 0 {
                opened()
                visit(sub)
            }
        }
        close(fd)
        closed()
    }
    let fd = open(root, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    if fd >= 0 {
        opened()
        visit(fd)
    }
    return c
}

// E. getattrlistbulk with N workers over a shared queue of directory paths (each worker holds one descriptor at a time).
func walkBulkParallel(_ root: String, workers: Int) -> Counts {
    let lock = NSCondition()
    var queue = [root]
    var busy = 0
    var total = Counts()
    let threads = (0 ..< workers)
        .map { _ in
            Thread {
                let buffer = UnsafeMutableRawPointer.allocate(byteCount: bulkSize, alignment: 16)
                defer { buffer.deallocate() }
                var local = Counts()
                while true {
                    lock.lock()
                    while queue.isEmpty && busy > 0 { lock.wait() }
                    guard let dir = queue.popLast() else {
                        lock.broadcast()
                        lock.unlock()
                        break
                    }
                    busy += 1
                    lock.unlock()
                    var found: [String] = []
                    let fd = open(dir, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    if fd >= 0 {
                        opened()
                        listBulk(fd, buffer, bulkSize) { n, k in
                            guard entered(n) else { return }
                            if count(n, k, into: &local) { found.append(dir + "/" + n) }
                        }
                        close(fd)
                        closed()
                    }
                    lock.lock()
                    queue += found
                    busy -= 1
                    lock.broadcast()
                    lock.unlock()
                }
                lock.lock()
                total.add(local)
                lock.unlock()
            }
        }
    let done = DispatchGroup()
    for thread in threads {
        done.enter()
        thread.stackSize = 1 << 20
        Thread.detachNewThread {
            thread.main()
            done.leave()
        }
    }
    done.wait()
    return total
}

/// The longest the work queue of F got: the descriptors an openat descent would hold open if each queued directory kept
/// its own descriptor until a worker took it.
nonisolated(unsafe) var peakQueue = 0

// F. readdir with d_type and N workers, the parallel form of B: no inode is read for an entry of known type.
func walkReaddirParallel(_ root: String, workers: Int) -> Counts {
    let lock = NSCondition()
    var queue = [root]
    var busy = 0
    var total = Counts()
    let done = DispatchGroup()
    for _ in 0 ..< workers {
        done.enter()
        Thread.detachNewThread {
            var local = Counts()
            while true {
                lock.lock()
                while queue.isEmpty && busy > 0 { lock.wait() }
                guard let dir = queue.popLast() else {
                    lock.broadcast()
                    lock.unlock()
                    break
                }
                busy += 1
                lock.unlock()
                var found: [String] = []
                let fd = open(dir, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if fd >= 0, let handle = fdopendir(fd) {
                    while let entry = readdir(handle) {
                        let n = name(of: entry)
                        guard n != ".", n != "..", entered(n) else { continue }
                        var k = kind(dType: entry.pointee.d_type)
                        if k == nil {
                            var s = stat()
                            local.stats += 1
                            k = fstatat(dirfd(handle), n, &s, AT_SYMLINK_NOFOLLOW) == 0 ? kind(mode: s.st_mode) : .other
                        }
                        if count(n, k!, into: &local) { found.append(dir + "/" + n) }
                    }
                    closedir(handle)
                }
                lock.lock()
                queue += found
                peakQueue = max(peakQueue, queue.count)
                busy -= 1
                lock.broadcast()
                lock.unlock()
            }
            lock.lock()
            total.add(local)
            lock.unlock()
            done.leave()
        }
    }
    done.wait()
    return total
}

func measure(_ label: String, runs: Int = 5, _ body: () -> Counts) -> Counts {
    _ = body()  // warm the caches; every measured run is warm
    var times: [Double] = []
    var result = Counts()
    for _ in 0 ..< runs {
        let start = DispatchTime.now().uptimeNanoseconds
        result = body()
        times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
    }
    times.sort()
    print(
        String(
            format: "%-26@ median %8.2f ms  min %8.2f  max %8.2f  stats %d", label as NSString, times[runs / 2],
            times[0],
            times[runs - 1], result.stats))
    return result
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    print("usage: walk-probe <root> [--shallow]")
    exit(64)
}
let root = URL(fileURLWithPath: arguments[1]).resolvingSymlinksInPath().path
print("root \(root)")
if arguments.contains("--shallow") {
    // One directory, not descended: what an ancestor lookup pays to look at it.
    let a = measure("FileManager listing", runs: 3) {
        var c = Counts()
        c.files = (try? FileManager.default.contentsOfDirectory(atPath: root))?.count ?? 0
        return c
    }
    let b = measure("readdir", runs: 3) {
        var c = Counts()
        if let h = opendir(root) {
            while let e = readdir(h) {
                _ = e
                c.files += 1
            }
            closedir(h)
        }
        c.files -= 2
        return c
    }
    let d = measure("getattrlistbulk", runs: 3) {
        var c = Counts()
        let fd = open(root, O_RDONLY | O_DIRECTORY)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bulkSize, alignment: 16)
        listBulk(fd, buffer, bulkSize) { _, _ in c.files += 1 }
        buffer.deallocate()
        close(fd)
        return c
    }
    print("entries: FileManager \(a.files), readdir \(b.files), getattrlistbulk \(d.files)")
    exit(0)
}
if let index = arguments.firstIndex(of: "--cold-against"), index + 1 < arguments.count {
    // Cold runs: before each one, stat every entry of a directory larger than the vnode cache (kern.maxvnodes), which
    // evicts the corpus's vnodes, so the walk pays what a first run after a checkout or a reboot pays.
    let evictor = arguments[index + 1]
    func evict() {
        guard let handle = opendir(evictor) else { return }
        while let entry = readdir(handle) {
            var s = stat()
            _ = fstatat(dirfd(handle), name(of: entry), &s, AT_SYMLINK_NOFOLLOW)
        }
        closedir(handle)
    }
    let methods: [(String, () -> Counts)] = [
        ("A FileManager+attributes", { walkFoundation(root) }), ("C openat + readdir", { walkOpenat(root) }),
        ("D getattrlistbulk", { walkBulk(root) }), ("E bulk, 4 workers", { walkBulkParallel(root, workers: 4) }),
        ("F readdir, 4 workers", { walkReaddirParallel(root, workers: 4) })
    ]
    var cold: [String: [Double]] = [:]
    for _ in 0 ..< 3 {
        for (label, body) in methods {
            evict()
            let start = DispatchTime.now().uptimeNanoseconds
            _ = body()
            cold[label, default: []].append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }
    }
    for (label, _) in methods {
        let times = cold[label]!.sorted()
        print(
            String(
                format: "cold %-26@ median %8.2f ms  min %8.2f  max %8.2f", label as NSString, times[1], times[0],
                times[2]))
    }
    exit(0)
}
let reference = measure("A FileManager+attributes") { walkFoundation(root) }
let results = [
    ("B readdir d_type (path)", measure("B readdir d_type (path)") { walkReaddirPath(root) }),
    ("C openat + readdir", measure("C openat + readdir") { walkOpenat(root) }),
    ("D getattrlistbulk", measure("D getattrlistbulk") { walkBulk(root) })
]
print("descriptors open at once, sequential openat descent: \(maximumDescriptors)")
var parallel: [(String, Counts)] = []
for workers in [1, 4, 8] {
    let label = "F readdir, \(workers) worker(s)"
    peakQueue = 0
    parallel.append((label, measure(label) { walkReaddirParallel(root, workers: workers) }))
    print("  directories queued at once, at most: \(peakQueue)")
}
for workers in [1, 2, 4, 8] {
    maximumDescriptors = 0
    let label = "E bulk, \(workers) worker(s)"
    parallel.append((label, measure(label) { walkBulkParallel(root, workers: workers) }))
    print("  descriptors open at once: \(maximumDescriptors)")
}
print("A: \(reference)")
for (label, counts) in results + parallel where counts != reference { print("MISMATCH \(label): \(counts)") }

import Testing

@testable import AemiIO

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Unique scratch path under the system temp dir; the caller `unlink`s it.
private func makeTempPath() -> String {
    "/tmp/adfio-\(getpid())-\(UInt64.random(in: 0..<UInt64.max)).bin"
}

@Suite struct PosixFileTests {
    @Test func writeThenReadRoundtrips() throws {
        let path = makeTempPath()
        let file = try PosixFile(path: path, mode: .readWrite(create: true))
        defer {
            file.close()
            _ = path.withCString { unlink($0) }
        }
        let payload: [UInt8] = Array("the quick brown fox".utf8)
        try payload.withUnsafeBytes { try file.pwrite($0, at: 0) }

        #expect(try file.fileSize() == payload.count)

        var readback = [UInt8](repeating: 0, count: payload.count)
        try readback.withUnsafeMutableBytes { try file.pread(into: $0, at: 0) }
        #expect(readback == payload)
    }

    @Test func vectoredWriteConcatenatesInOrder() throws {
        let path = makeTempPath()
        let file = try PosixFile(path: path, mode: .readWrite(create: true))
        defer {
            file.close()
            _ = path.withCString { unlink($0) }
        }
        let a: [UInt8] = [1, 2, 3]
        let b: [UInt8] = [4, 5]
        let c: [UInt8] = [6, 7, 8, 9]
        try a.withUnsafeBytes { pa in
            try b.withUnsafeBytes { pb in
                try c.withUnsafeBytes { pc in
                    try file.pwritev([pa, pb, pc], at: 0)
                }
            }
        }
        var readback = [UInt8](repeating: 0, count: 9)
        try readback.withUnsafeMutableBytes { try file.pread(into: $0, at: 0) }
        #expect(readback == [1, 2, 3, 4, 5, 6, 7, 8, 9])
    }

    @Test func preallocateGrowsAndTruncateShrinks() throws {
        let path = makeTempPath()
        let file = try PosixFile(path: path, mode: .readWrite(create: true))
        defer {
            file.close()
            _ = path.withCString { unlink($0) }
        }
        try file.preallocate(minimumSize: 8192)
        #expect(try file.fileSize() == 8192)
        try file.truncate(to: 100)
        #expect(try file.fileSize() == 100)
    }

    @Test func badPathThrowsIOErrorWithErrno() {
        #expect(throws: IOError.self) {
            _ = try PosixFile(path: "/nonexistent-dir-xyz/file.bin", mode: .readOnly)
        }
    }

    @Test func vectoredWriteBatchesBeyondIOVMaxWithEmptyBuffers() throws {
        let path = makeTempPath()
        let file = try PosixFile(path: path, mode: .readWrite(create: true))
        defer {
            file.close()
            _ = path.withCString { unlink($0) }
        }
        // More iovecs than IOV_MAX (1024 on the supported platforms) forces the chunked batch loop;
        // interleaved empty buffers exercise the zero-length iovec handling.
        let logicalCount = 1100
        var payload: [UInt8] = []
        var empties: [Bool] = []
        for i in 0 ..< logicalCount {
            let isEmpty = i % 7 == 0
            empties.append(isEmpty)
            if !isEmpty { payload.append(UInt8(i & 0xFF)) }
        }
        try payload.withUnsafeBytes { raw in
            var views: [UnsafeRawBufferPointer] = []
            views.reserveCapacity(logicalCount)
            var cursor = 0
            for isEmpty in empties {
                if isEmpty {
                    views.append(UnsafeRawBufferPointer(start: nil, count: 0))
                } else {
                    views.append(UnsafeRawBufferPointer(rebasing: raw[cursor ..< (cursor + 1)]))
                    cursor += 1
                }
            }
            try file.pwritev(views, at: 0)
        }
        var readback = [UInt8](repeating: 0, count: payload.count)
        try readback.withUnsafeMutableBytes { try file.pread(into: $0, at: 0) }
        #expect(readback == payload)
        #expect(try file.fileSize() == payload.count)
    }

    @Test func syncProfilesDoNotThrow() throws {
        let path = makeTempPath()
        let file = try PosixFile(path: path, mode: .readWrite(create: true))
        defer {
            file.close()
            _ = path.withCString { unlink($0) }
        }
        let payload: [UInt8] = [1, 2, 3, 4]
        try payload.withUnsafeBytes { try file.pwrite($0, at: 0) }
        try file.sync(.none)
        try file.sync(.barrier)
        try file.sync(.full)
        #expect(try file.fileSize() == 4)
    }

    @Test func setNoCacheTogglesWithoutThrowing() throws {
        let path = makeTempPath()
        let file = try PosixFile(path: path, mode: .readWrite(create: true))
        defer {
            file.close()
            _ = path.withCString { unlink($0) }
        }
        file.setNoCache(true)
        file.setNoCache(false)
    }

    @Test func preallocateIsIdempotentWhenAlreadyLargeEnough() throws {
        let path = makeTempPath()
        let file = try PosixFile(path: path, mode: .readWrite(create: true))
        defer {
            file.close()
            _ = path.withCString { unlink($0) }
        }
        try file.preallocate(minimumSize: 4096)
        #expect(try file.fileSize() == 4096)
        try file.preallocate(minimumSize: 1000)  // already larger → no-op
        #expect(try file.fileSize() == 4096)
    }
}

@Suite struct RawFileMapTests {
    @Test func mappedRegionReflectsFileBytes() throws {
        let path = makeTempPath()
        let file = try PosixFile(path: path, mode: .readWrite(create: true))
        defer {
            file.close()
            _ = path.withCString { unlink($0) }
        }
        let payload = [UInt8](0 ..< 64)
        try payload.withUnsafeBytes { try file.pwrite($0, at: 0) }
        try file.sync(.barrier)

        let map = try RawFileMap(fileDescriptor: file.fileDescriptor, capacity: 64)
        map.prefetch(offset: 0, length: 64)
        let region = map.region(offset: 0, count: 64)
        #expect(Array(region) == payload)
        #expect(map.capacity == 64)
    }

    /// The additive, lifetime-checked `withRegion` accessor vends a `RawSpan` over the same bytes as
    /// the unchecked `region`, and its `offset` arithmetic matches. Guards the safe scoped path added
    /// alongside `region` (which stays for zero-copy callers holding pointers across the map's life).
    @Test func withRegionVendsAScopedSpanMatchingTheUncheckedView() throws {
        let path = makeTempPath()
        let file = try PosixFile(path: path, mode: .readWrite(create: true))
        defer {
            file.close()
            _ = path.withCString { unlink($0) }
        }
        let payload = [UInt8](0 ..< 64)
        try payload.withUnsafeBytes { try file.pwrite($0, at: 0) }
        try file.sync(.barrier)

        let map = try RawFileMap(fileDescriptor: file.fileDescriptor, capacity: 64)
        // Full window: reading the span inside the closure reproduces every file byte.
        let copied: [UInt8] = map.withRegion(offset: 0, count: 64) { span in
            #expect(span.byteCount == 64)
            return (0 ..< span.byteCount).map { span.unsafeLoad(fromByteOffset: $0, as: UInt8.self) }
        }
        #expect(copied == payload)
        // A sub-window at a non-zero offset must match the equivalent `region` slice byte-for-byte.
        let mid: [UInt8] = map.withRegion(offset: 8, count: 4) { span in
            (0 ..< span.byteCount).map { span.unsafeLoad(fromByteOffset: $0, as: UInt8.self) }
        }
        #expect(mid == Array(payload[8 ..< 12]))
        #expect(mid == Array(map.region(offset: 8, count: 4)))
    }

    @Test func prefetchClampsAndIgnoresOutOfRange() throws {
        let path = makeTempPath()
        let file = try PosixFile(path: path, mode: .readWrite(create: true))
        defer {
            file.close()
            _ = path.withCString { unlink($0) }
        }
        let payload = [UInt8](0 ..< 32)
        try payload.withUnsafeBytes { try file.pwrite($0, at: 0) }
        try file.sync(.barrier)

        let map = try RawFileMap(fileDescriptor: file.fileDescriptor, capacity: 32)
        map.prefetch(offset: 100, length: 8)  // offset past capacity → no-op
        map.prefetch(offset: 16, length: 4096)  // length clamped to the reserved capacity
        map.prefetch(offset: 0, length: 0)  // zero length → no-op
        #expect(Array(map.region(offset: 0, count: 32)) == payload)
    }

    @Test func zeroCapacityMapThrows() throws {
        let path = makeTempPath()
        let file = try PosixFile(path: path, mode: .readWrite(create: true))
        defer {
            file.close()
            _ = path.withCString { unlink($0) }
        }
        #expect(throws: IOError.self) {
            _ = try RawFileMap(fileDescriptor: file.fileDescriptor, capacity: 0)
        }
    }
}

@Suite struct IOErrorTests {
    /// Exercises the platform `strerror_r` formatting path (XSI on Darwin, GNU on Glibc) — it must
    /// produce a non-empty message and never read uninitialized memory.
    @Test func descriptionFormatsErrnoWithoutReadingGarbage() {
        let text = IOError(errno: ENOENT, op: "open").description
        #expect(text.hasPrefix("I/O error in open: "))
        #expect(text.contains("(errno 2)"))  // ENOENT == 2 on Darwin and Linux
        #expect(text.contains("No such file"))  // strerror(ENOENT), proving the buffer was filled
    }
}

@Suite struct AtomicsTests {
    /// Exercises ``SharedAtomicU64`` over local (aligned) `UInt64` storage.
    @Test func compareExchangeHasReleaseAcquireSemantics() {
        withUnsafeTemporaryAllocation(of: UInt64.self, capacity: 1) { buffer in
            let p = UnsafeMutableRawPointer(buffer.baseAddress!)
            SharedAtomicU64.storeRelease(p, 0)
            #expect(SharedAtomicU64.loadAcquire(p) == 0)

            #expect(SharedAtomicU64.compareExchangeAcqRel(p, expected: 0, desired: 5))  // 0 → 5 succeeds
            #expect(SharedAtomicU64.loadAcquire(p) == 5)

            #expect(!SharedAtomicU64.compareExchangeAcqRel(p, expected: 0, desired: 9))  // holds 5 → fails
            #expect(SharedAtomicU64.loadAcquire(p) == 5)
        }
    }
}

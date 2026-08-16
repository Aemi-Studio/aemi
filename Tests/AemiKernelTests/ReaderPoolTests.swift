import AemiKernel
import Testing

struct ByteReaderTests {
    @Test func readsLittleEndianScalarsThenSignalsEnd() {
        var bytes: [UInt8] = []
        bytes.append(contentsOf: withUnsafeBytes(of: UInt32(0xDEAD_BEEF).littleEndian) { Array($0) })
        bytes.append(contentsOf: withUnsafeBytes(of: UInt64(0x0102_0304_0506_0708).littleEndian) { Array($0) })
        bytes.append(contentsOf: withUnsafeBytes(of: Double(3.5).bitPattern.littleEndian) { Array($0) })
        bytes.withUnsafeBytes { raw in
            var reader = ByteReader(raw)
            // Bind mutating reads to locals: Swift Testing's `#expect` borrows its operands
            // immutably, so a `mutating` call cannot appear directly inside it.
            let a = reader.u32()
            let b = reader.u64()
            let c = reader.f64()
            let rem = reader.remaining
            let past = reader.u32()
            #expect(a == 0xDEAD_BEEF)
            #expect(b == 0x0102_0304_0506_0708)
            #expect(c == 3.5)
            #expect(rem == 0)
            #expect(past == nil)  // past end: no trap, returns nil
        }
    }

    @Test func boundsCheckedBytesView() {
        let bytes: [UInt8] = [10, 20, 30, 40]
        bytes.withUnsafeBytes { raw in
            var reader = ByteReader(raw)
            let oob = reader.bytes(5)  // out of bounds
            let view = reader.bytes(3)
            #expect(oob == nil)
            #expect(view.map { Array($0) } == [10, 20, 30])  // the right 3 bytes, not merely 3 of them
            #expect(reader.remaining == 1)
        }
    }

    @Test func align8AdvancesToBoundary() {
        let bytes = [UInt8](repeating: 0, count: 16)
        bytes.withUnsafeBytes { raw in
            var reader = ByteReader(raw)
            _ = reader.u32()  // offset 4
            let aligned = reader.align8()
            #expect(aligned)
            #expect(reader.offset == 8)
        }
    }

    @Test func align8IsNoOpWhenAlreadyAligned() {
        let bytes = [UInt8](repeating: 0, count: 16)
        bytes.withUnsafeBytes { raw in
            var reader = ByteReader(raw)
            _ = reader.u64()  // offset 8, already on an 8-byte boundary
            let aligned = reader.align8()
            #expect(aligned)
            #expect(reader.offset == 8)
        }
    }

    @Test func align8FailsWhenPaddingRunsPastEnd() {
        let bytes = [UInt8](repeating: 0, count: 5)
        bytes.withUnsafeBytes { raw in
            var reader = ByteReader(raw)
            _ = reader.u32()  // offset 4; aligning needs 4 pad bytes but only 1 remains
            let aligned = reader.align8()
            #expect(!aligned)
            #expect(reader.offset == 4)  // unchanged on failure
        }
    }

    @Test func readsBytesHalvesWordsAndBigEndian() {
        let bytes: [UInt8] = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09]
        bytes.withUnsafeBytes { raw in
            var reader = ByteReader(raw)
            let a = reader.u8()
            let b = reader.u16()  // little-endian 0x0302
            let c = reader.u16be()  // big-endian 0x0405
            let d = reader.u32be()  // big-endian 0x06070809
            let rem = reader.remaining
            #expect(a == 0x01)
            #expect(b == 0x0302)
            #expect(c == 0x0405)
            #expect(d == 0x0607_0809)
            #expect(rem == 0)
        }
    }

    @Test func u64beReadsBigEndian() {
        let bytes: [UInt8] = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]
        bytes.withUnsafeBytes { raw in
            var reader = ByteReader(raw)
            let v = reader.u64be()
            #expect(v == 0x0102_0304_0506_0708)
        }
    }

    @Test func partialBoundaryReadsReturnNil() {
        let bytes: [UInt8] = [1, 2, 3]
        bytes.withUnsafeBytes { raw in
            var reader = ByteReader(raw)
            let a = reader.u32()  // needs 4, only 3 remain → nil, offset unchanged
            let b = reader.u16()  // 2 available → ok
            let c = reader.u16()  // 1 left → nil
            #expect(a == nil)
            #expect(b == 0x0201)
            #expect(c == nil)
            #expect(reader.remaining == 1)
        }
    }

    @Test func skipAdvancesAndRejectsOverrun() {
        let bytes = [UInt8](repeating: 0, count: 8)
        bytes.withUnsafeBytes { raw in
            var reader = ByteReader(raw)
            // Bind mutating calls to locals: `#expect` borrows its operands immutably.
            let s1 = reader.skip(3)
            let offsetAfterSkip = reader.offset
            let s2 = reader.skip(10)  // past end → false, offset unchanged
            let offsetAfterOverrun = reader.offset
            let s3 = reader.skip(-1)  // negative → false
            let s4 = reader.skip(5)
            let rem = reader.remaining
            #expect(s1)
            #expect(offsetAfterSkip == 3)
            #expect(!s2)
            #expect(offsetAfterOverrun == 3)
            #expect(!s3)
            #expect(s4)
            #expect(rem == 0)
        }
    }
}

struct ByteBufferPoolTests {
    @Test func emptyPoolYieldsFreshBuffer() {
        let pool = ByteBufferPool()
        #expect(pool.take().isEmpty)
    }

    @Test func recycleClearsButRetainsCapacity() {
        let pool = ByteBufferPool()
        var b = pool.take()
        b.append(contentsOf: [1, 2, 3, 4, 5])
        pool.recycle(b)
        let reused = pool.take()
        #expect(reused.isEmpty)
        #expect(reused.capacity >= 5)
    }

    @Test func oversizedBufferIsNotPooled() {
        let pool = ByteBufferPool(maxBufferCapacity: 8, maxPooled: 4)
        var big = pool.take()
        big.reserveCapacity(1024)
        pool.recycle(big)
        // Dropped, not pooled: the next take starts fresh with no retained large capacity.
        #expect(pool.take().capacity < 1024)
    }

    @Test func respectsMaxPooledCount() {
        let pool = ByteBufferPool(maxPooled: 2)
        for _ in 0 ..< 5 {
            var b: [UInt8] = []
            b.reserveCapacity(64)
            pool.recycle(b)
        }
        // Only `maxPooled` buffers are retained; the other three recycles were dropped.
        #expect(pool.take().capacity >= 64)
        #expect(pool.take().capacity >= 64)
        #expect(pool.take().capacity == 0)  // pool exhausted → fresh empty buffer
    }

    /// Concurrent take/recycle must not drop or corrupt buffers; run under the thread sanitizer this
    /// also proves the `Mutex` guards the pool against data races.
    @Test func concurrentTakeAndRecycleIsThreadSafe() async {
        let pool = ByteBufferPool(maxBufferCapacity: 1 << 16, maxPooled: 16)
        let total = await withTaskGroup(of: Int.self) { group in
            for _ in 0 ..< 8 {
                group.addTask {
                    var sum = 0
                    for _ in 0 ..< 5000 {
                        var b = pool.take()
                        b.append(contentsOf: [1, 2, 3, 4])
                        sum += b.count
                        pool.recycle(b)
                    }
                    return sum
                }
            }
            var acc = 0
            for await s in group { acc += s }
            return acc
        }
        #expect(total == 8 * 5000 * 4)
    }
}

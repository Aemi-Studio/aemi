import AemiKernel
import Testing

struct VarintTests {
    @Test func roundTripAcrossArrayReader() {
        for v in [UInt64(0), 1, 127, 128, 300, 16384, 1 << 35, UInt64.max] {
            var bytes: [UInt8] = []
            Varint.append(v, to: &bytes)
            var offset = 0
            #expect(Varint.read(bytes, &offset) == v)
            #expect(offset == bytes.count)
        }
    }

    @Test func rawBufferReaderMatchesArrayReader() {
        var bytes: [UInt8] = []
        Varint.append(300, to: &bytes)
        let viaRaw = bytes.withUnsafeBytes { raw -> UInt64? in
            var offset = 0
            return Varint.read(raw, &offset)
        }
        #expect(viaRaw == 300)
    }

    @Test func truncationReturnsNil() {
        var offset = 0
        #expect(Varint.read([0x80] as [UInt8], &offset) == nil)
    }

    @Test func overflowPast64BitsReturnsNil() {
        let overlong = [UInt8](repeating: 0x80, count: 10) + [0x01]
        var offset = 0
        #expect(Varint.read(overlong, &offset) == nil)
    }

    @Test func tenthByteOverflowBitsRejected() {
        // A 10th group whose payload exceeds bit 63 must fail cleanly, not silently truncate.
        var offset = 0
        #expect(Varint.read([UInt8](repeating: 0x80, count: 9) + [0x02], &offset) == nil)
        // The maximal in-range 10-byte encoding (only bit 63 set) still decodes.
        offset = 0
        #expect(Varint.read([UInt8](repeating: 0x80, count: 9) + [0x01], &offset) == 1 << 63)
    }

    @Test func zigzagRoundTrip() {
        for v in [Int64(0), -1, 1, -2, 2, -1000, 1000, Int64.min, Int64.max] {
            #expect(Varint.unzigzag(Varint.zigzag(v)) == v)
        }
    }

    @Test func outputSpanFormMatchesArrayForm() {
        for v in [UInt64(0), 1, 127, 128, 300, 16384, 1 << 35, UInt64.max] {
            var viaArray: [UInt8] = []
            Varint.append(v, to: &viaArray)
            // Build the same varint into an exclusively-owned OutputSpan sized to the worst case.
            let viaSpan = [UInt8](capacity: Varint.maxEncodedLength) { out in
                Varint.append(v, to: &out)
            }
            #expect(viaSpan == viaArray)
            #expect(viaArray.count <= Varint.maxEncodedLength)
            var offset = 0
            #expect(Varint.read(viaSpan, &offset) == v)
            #expect(offset == viaSpan.count)
        }
    }
}

struct EndianTests {
    @Test func littleAndBigEndianLoads() {
        let bytes: [UInt8] = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]
        bytes.withUnsafeBytes { raw in
            #expect(raw.loadLE16(0) == 0x0201)
            #expect(raw.loadLE32(0) == 0x0403_0201)
            #expect(raw.loadLE64(0) == 0x0807_0605_0403_0201)
            #expect(raw.loadBE64(0) == 0x0102_0304_0506_0708)
        }
    }

    @Test func storeRoundTrip() {
        var bytes = [UInt8](repeating: 0, count: 8)
        bytes.withUnsafeMutableBytes { raw in
            raw.storeLE16(0xBEEF, at: 0)
            #expect(raw.loadLE16(0) == 0xBEEF)
            raw.storeLE32(0xDEAD_BEEF, at: 0)
            #expect(raw.loadLE32(0) == 0xDEAD_BEEF)
            raw.storeLE64(0x0102_0304_0506_0708, at: 0)
            #expect(raw.loadLE64(0) == 0x0102_0304_0506_0708)
        }
    }

    @Test func appendFormProducesLittleEndianBytes() {
        // The append helpers emit the canonical little-endian byte sequence (LSB first), the golden
        // the wire/disk builders depend on.
        var out: [UInt8] = []
        out.appendLE16(0x0201)
        out.appendLE32(0x0605_0403)
        out.appendLE64(0x0E0D_0C0B_0A09_0807)
        let expected: [UInt8] = [
            0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E
        ]
        #expect(out == expected)
    }

    @Test func appendFormMatchesBufferStores() {
        // The append helpers must emit bytes identical to the store-at-offset helpers, so a builder
        // that mixes the two forms (a frame header patched in place, then cells appended) stays coherent.
        let cases: [(UInt16, UInt32, UInt64)] = [
            (0, 0, 0),
            (0xBEEF, 0xDEAD_BEEF, 0x0102_0304_0506_0708),
            (0xFFFF, 0xFFFF_FFFF, 0xFFFF_FFFF_FFFF_FFFF),
            (1, 0x00AB_CDEF, 0x00FF_00FF_00FF_00FF)
        ]
        for (v16, v32, v64) in cases {
            var viaAppend: [UInt8] = []
            viaAppend.appendLE16(v16)
            viaAppend.appendLE32(v32)
            viaAppend.appendLE64(v64)
            var viaStore = [UInt8](repeating: 0, count: 14)
            viaStore.withUnsafeMutableBytes { raw in
                raw.storeLE16(v16, at: 0)
                raw.storeLE32(v32, at: 2)
                raw.storeLE64(v64, at: 6)
            }
            #expect(viaAppend == viaStore)
            // Round-trip through the immutable loads recovers the values.
            viaAppend.withUnsafeBytes { raw in
                #expect(raw.loadLE16(0) == v16)
                #expect(raw.loadLE32(2) == v32)
                #expect(raw.loadLE64(6) == v64)
            }
        }
    }

    @Test func loadsAndStoresAtNonZeroOffset() {
        var bytes = [UInt8](repeating: 0, count: 16)
        bytes.withUnsafeMutableBytes { raw in
            raw.storeLE16(0xBEEF, at: 2)
            raw.storeLE32(0xDEAD_BEEF, at: 4)
            raw.storeLE64(0x0102_0304_0506_0708, at: 8)
            #expect(raw.loadLE16(2) == 0xBEEF)
            #expect(raw.loadLE32(4) == 0xDEAD_BEEF)
            #expect(raw.loadLE64(8) == 0x0102_0304_0506_0708)
        }
        // The mutable-buffer loads delegate to the immutable view — verify parity at a non-zero offset.
        bytes.withUnsafeBytes { raw in
            #expect(raw.loadLE16(2) == 0xBEEF)
            #expect(raw.loadBE64(8) == 0x0807_0605_0403_0201)
        }
    }

    @Test func bigEndianStoresAndLoadsRoundTrip() {
        var bytes = [UInt8](repeating: 0, count: 16)
        bytes.withUnsafeMutableBytes { raw in
            raw.storeBE16(0xBEEF, at: 0)
            raw.storeBE32(0xDEAD_BEEF, at: 2)
            raw.storeBE64(0x0102_0304_0506_0708, at: 6)
            #expect(raw.loadBE16(0) == 0xBEEF)
            #expect(raw.loadBE32(2) == 0xDEAD_BEEF)
            #expect(raw.loadBE64(6) == 0x0102_0304_0506_0708)
            // Byte order really is big-endian: most-significant byte first.
            #expect(raw[0] == 0xBE)
            #expect(raw[1] == 0xEF)
        }
        // Parity through the immutable view (loads delegate there).
        bytes.withUnsafeBytes { raw in
            #expect(raw.loadBE16(0) == 0xBEEF)
            #expect(raw.loadBE32(2) == 0xDEAD_BEEF)
            #expect(raw.loadBE64(6) == 0x0102_0304_0506_0708)
        }
    }

    // MARK: - Span parallels

    /// The `MutableRawSpan` store/load helpers must produce bytes identical to the
    /// `UnsafeMutableRawBufferPointer` helpers (ADDB's page codec vends a span; the on-disk format
    /// is byte-critical, so a divergent encoding here would silently corrupt the B+tree).
    @Test func spanStoresMatchBufferPointerBytes() {
        let cases: [(UInt16, UInt32, UInt64)] = [
            (0, 0, 0),
            (0xBEEF, 0xDEAD_BEEF, 0x0102_0304_0506_0708),
            (0xFFFF, 0xFFFF_FFFF, 0xFFFF_FFFF_FFFF_FFFF),
            (1, 0x00AB_CDEF, 0x00FF_00FF_00FF_00FF)
        ]
        for (v16, v32, v64) in cases {
            for off in [0, 2, 4, 6] {
                var viaPtr = [UInt8](repeating: 0, count: 32)
                var viaSpanLE = [UInt8](repeating: 0, count: 32)
                var viaSpanBE = [UInt8](repeating: 0, count: 32)
                var viaPtrBE = [UInt8](repeating: 0, count: 32)
                viaPtr.withUnsafeMutableBytes { raw in
                    raw.storeLE16(v16, at: off)
                    raw.storeLE32(v32, at: off + 8)
                    raw.storeLE64(v64, at: off + 16)
                }
                viaPtrBE.withUnsafeMutableBytes { raw in
                    raw.storeBE16(v16, at: off)
                    raw.storeBE32(v32, at: off + 8)
                    raw.storeBE64(v64, at: off + 16)
                }
                viaSpanLE.withUnsafeMutableBytes { raw in
                    var span = MutableRawSpan(_unsafeBytes: raw)
                    span.storeLE16(v16, at: off)
                    span.storeLE32(v32, at: off + 8)
                    span.storeLE64(v64, at: off + 16)
                    // Read-during-write must round-trip through the span itself.
                    #expect(span.loadLE16(off) == v16)
                    #expect(span.loadLE32(off + 8) == v32)
                    #expect(span.loadLE64(off + 16) == v64)
                }
                viaSpanBE.withUnsafeMutableBytes { raw in
                    var span = MutableRawSpan(_unsafeBytes: raw)
                    span.storeBE16(v16, at: off)
                    span.storeBE32(v32, at: off + 8)
                    span.storeBE64(v64, at: off + 16)
                    #expect(span.loadBE16(off) == v16)
                    #expect(span.loadBE32(off + 8) == v32)
                    #expect(span.loadBE64(off + 16) == v64)
                }
                #expect(viaSpanLE == viaPtr, "LE span/pointer byte mismatch at offset \(off)")
                #expect(viaSpanBE == viaPtrBE, "BE span/pointer byte mismatch at offset \(off)")
            }
        }
    }

    /// `RawSpan` loads must match the `UnsafeRawBufferPointer` loads byte-for-byte over the same
    /// fixed pattern (the read side of the page codec).
    @Test func rawSpanLoadsMatchBufferPointerLoads() {
        let bytes: [UInt8] = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]
        bytes.withUnsafeBytes { raw in
            let span = RawSpan(_unsafeBytes: raw)
            #expect(span.loadLE16(0) == raw.loadLE16(0))
            #expect(span.loadLE32(0) == raw.loadLE32(0))
            #expect(span.loadLE64(0) == raw.loadLE64(0))
            #expect(span.loadBE16(0) == raw.loadBE16(0))
            #expect(span.loadBE32(0) == raw.loadBE32(0))
            #expect(span.loadBE64(0) == raw.loadBE64(0))
            // Spot-check the absolute values too.
            #expect(span.loadLE64(0) == 0x0807_0605_0403_0201)
            #expect(span.loadBE64(0) == 0x0102_0304_0506_0708)
        }
    }
}

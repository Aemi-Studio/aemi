import AemiKernel
import Testing

struct TapeSlotTests {
    @Test func packsAndUnpacksEachField() {
        let offset = Int(UInt64(0x89AB_CDEF) & UInt64(Int.max))
        let s = TapeSlot.make(tag: 0xA, aux: 0x0123_456, low: offset)
        #expect(TapeSlot.tag(s) == 0xA)
        #expect(TapeSlot.aux(s) == 0x0123_456)
        #expect(TapeSlot.low(s) == offset)
    }

    @Test func fieldsAreIndependent() {
        // Each field round-trips at its maximum without bleeding into the others.
        #expect(UInt64(TapeSlot.maxLow) == min(UInt64(Int.max), TapeSlot.lowMask))
        let s = TapeSlot.make(tag: 0xF, aux: UInt64(TapeSlot.maxAux), low: TapeSlot.maxLow)
        #expect(TapeSlot.tag(s) == 0xF)
        #expect(TapeSlot.aux(s) == UInt64(TapeSlot.maxAux))
        #expect(TapeSlot.low(s) == TapeSlot.maxLow)
    }

    @Test func auxIsMaskedToTwentyEightBits() {
        // Bits above 28 are dropped, never corrupting the tag.
        let s = TapeSlot.make(tag: 0x3, aux: 0xFFFF_FFFF, low: 0)
        #expect(TapeSlot.tag(s) == 0x3)
        #expect(TapeSlot.aux(s) == UInt64(TapeSlot.maxAux))
    }

    @Test func modelsADJSONScalarAndContainerEncodings() {
        // The kernel reproduces ADJSON's two slot shapes (scalar: aux = (length<<2)|flags; container:
        // aux = count, low = next), proving it generalizes the value tape it was promoted from.
        let scalar = TapeSlot.make(tag: 4, aux: (UInt64(1000) << 2) | 0b01, low: 42)
        #expect(TapeSlot.aux(scalar) >> 2 == 1000)  // length
        #expect(TapeSlot.aux(scalar) & 0b11 == 0b01)  // flags
        #expect(TapeSlot.low(scalar) == 42)  // offset

        let container = TapeSlot.make(tag: 6, aux: 7, low: 99)
        #expect(TapeSlot.next(after: 3, container, isContainer: true) == 99)  // O(1) subtree skip
        #expect(TapeSlot.next(after: 3, scalar, isContainer: false) == 4)  // leaf advances by one
    }
}

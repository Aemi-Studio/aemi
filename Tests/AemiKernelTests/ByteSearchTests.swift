import AemiKernel
import Testing

struct ByteSearchTests {
    @Test func findsNeedleAtStartMiddleAndEnd() {
        let hay: [UInt8] = [1, 2, 3, 4, 5]
        #expect(ByteSearch.firstRange(of: [1, 2], in: hay[...]) == 0 ..< 2)
        #expect(ByteSearch.firstRange(of: [3, 4], in: hay[...]) == 2 ..< 4)
        #expect(ByteSearch.firstRange(of: [4, 5], in: hay[...]) == 3 ..< 5)
        #expect(ByteSearch.firstRange(of: [5], in: hay[...]) == 4 ..< 5)
    }

    @Test func returnsTheFirstOfMultipleOccurrences() {
        let hay: [UInt8] = [7, 0, 7, 0, 7]
        #expect(ByteSearch.firstRange(of: [7, 0], in: hay[...]) == 0 ..< 2)
    }

    @Test func absentEmptyAndOversizedNeedlesReturnNil() {
        let hay: [UInt8] = [1, 2, 3]
        #expect(ByteSearch.firstRange(of: [9], in: hay[...]) == nil)  // absent
        #expect(ByteSearch.firstRange(of: [], in: hay[...]) == nil)  // empty needle
        #expect(ByteSearch.firstRange(of: [1, 2, 3, 4], in: hay[...]) == nil)  // longer than haystack
    }

    /// An `ArraySlice` keeps its parent's indices; the returned range MUST be in those indices —
    /// the multipart `split` relies on this when it rescans `bytes[start...]`.
    @Test func rangeIsExpressedInTheSlicesOwnIndices() {
        let hay: [UInt8] = [9, 9, 1, 2, 3]
        let slice = hay[2...]  // indices 2, 3, 4
        #expect(ByteSearch.firstRange(of: [2, 3], in: slice) == 3 ..< 5)
    }

    @Test func splitProducesSlicesBetweenSeparators() {
        let bytes: [UInt8] = [1, 0, 2, 0, 3]
        #expect(ByteSearch.split(bytes, on: [0]).map(Array.init) == [[1], [2], [3]])
    }

    @Test func splitWithoutSeparatorReturnsTheWholeInput() {
        let bytes: [UInt8] = [1, 2, 3]
        #expect(ByteSearch.split(bytes, on: [9]).map(Array.init) == [[1, 2, 3]])
        #expect(ByteSearch.split(bytes, on: []).map(Array.init) == [[1, 2, 3]])  // empty separator
    }

    @Test func splitYieldsEmptySlicesAtBoundariesAndBetweenAdjacentSeparators() {
        let bytes: [UInt8] = [0, 1, 0, 0, 2, 0]  // leading + adjacent + trailing separators
        #expect(ByteSearch.split(bytes, on: [0]).map(Array.init) == [[], [1], [], [2], []])
    }

    @Test func splitOnMultiByteSeparator() {
        let bytes: [UInt8] = [1, 13, 10, 2, 13, 10, 3]  // CRLF-separated
        #expect(ByteSearch.split(bytes, on: [13, 10]).map(Array.init) == [[1], [2], [3]])
    }
}

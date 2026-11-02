//
//  AemiKernels+Find.swift
//  AemiKernels
//
//  The first occurrence of a byte string, behind `AemiKernel.ByteSearch`. The SIMD kernel filters starts by their first and last
//  byte; when a crafted input makes it compare too much (its budget is linear in the haystack) it stops, and the search finishes
//  here with Knuth-Morris-Pratt from where it stopped, so no input costs more than linear time.
//

internal import CAemiKernels

extension AemiKernels {
    /// The first index of `needle` in `haystack`, or `nil`. An empty needle is found at 0.
    ///
    /// - Complexity: O(`haystack.count` + `needle.count`) whatever the input.
    package static func firstIndex(of needle: UnsafeBufferPointer<UInt8>, in haystack: UnsafeBufferPointer<UInt8>)
        -> Int?
    {
        guard !needle.isEmpty else { return 0 }
        guard needle.count <= haystack.count, let hay = haystack.baseAddress, let pattern = needle.baseAddress else {
            return nil
        }
        var resume = 0
        let found = unsafe adf_find(hay, haystack.count, pattern, needle.count, &resume)
        if found == -1 { return nil }  // SIZE_MAX
        if found == -2 {  // ADF_FIND_GAVE_UP
            precondition(
                resume >= 0 && resume <= haystack.count - needle.count,
                "the search kernel stopped at \(resume)"
            )
            return unsafe knuthMorrisPratt(needle, in: haystack, from: resume)
        }
        precondition(found >= 0 && found <= haystack.count - needle.count, "the search kernel returned \(found)")
        return found
    }

    /// The first index at or after `from` where `needle` starts, in linear time.
    static func knuthMorrisPratt(
        _ needle: UnsafeBufferPointer<UInt8>,
        in haystack: UnsafeBufferPointer<UInt8>,
        from: Int
    ) -> Int? {
        let n = needle.count
        // failure[k]: the length of the longest proper border of needle[0 ... k].
        var failure = [Int](repeating: 0, count: n)
        var border = 0
        for k in 1 ..< max(n, 1) {
            while border > 0, unsafe needle[k] != needle[border] { border = failure[border - 1] }
            if unsafe needle[k] == needle[border] { border += 1 }
            failure[k] = border
        }
        var matched = 0
        var index = from
        while index < haystack.count {
            while matched > 0, unsafe haystack[index] != needle[matched] { matched = failure[matched - 1] }
            if unsafe haystack[index] == needle[matched] { matched += 1 }
            if matched == n { return index - n + 1 }
            index += 1
        }
        return nil
    }
}

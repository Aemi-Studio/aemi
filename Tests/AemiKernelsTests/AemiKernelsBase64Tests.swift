import AemiKernels
import AemiTestKit
import Testing

/// The Base64 block kernels' facade (`package` API): its inputs and outputs flush against inaccessible pages, so a read or a
/// store one byte outside the contract crashes (aemi ADR 0021), and every way of calling it wrongly traps before the kernel runs.
struct AemiKernelsBase64Tests {
    static let symbols = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)
    static let lookup: [UInt8] = {
        var table = [UInt8](repeating: 0xFF, count: 256)
        for (value, byte) in symbols.enumerated() { table[Int(byte)] = UInt8(value) }
        return table
    }()
    static let tail = UInt16(UInt8(ascii: "+")) | UInt16(UInt8(ascii: "/")) << 8
    static let lengths = Array(0 ... 200) + [255, 256, 257, 1023, 4095, 4096, 4097]

    private func encode(
        _ input: UnsafeMutablePointer<UInt8>,
        _ count: Int,
        _ output: UnsafeMutablePointer<UInt8>,
        backend: AemiKernels.Backend
    ) -> Int {
        Self.symbols.withUnsafeBufferPointer { table in
            AemiKernels.base64EncodeBlocks(
                table: table,
                tail: Self.tail,
                input: UnsafeBufferPointer(start: input, count: count),
                output: UnsafeMutableBufferPointer(start: output, count: count / 3 * 4),
                backend: backend
            )
        }
    }

    private func decode(
        _ input: UnsafeMutablePointer<UInt8>,
        _ count: Int,
        _ output: UnsafeMutablePointer<UInt8>,
        backend: AemiKernels.Backend
    ) -> Int {
        Self.lookup.withUnsafeBufferPointer { table in
            AemiKernels.base64DecodeBlocks(
                lookup: table,
                tail: Self.tail,
                input: UnsafeBufferPointer(start: input, count: count),
                output: UnsafeMutableBufferPointer(start: output, count: count / 4 * 3),
                backend: backend
            )
        }
    }

    @Test func `encoding stays inside an input and an output that end at a guard page`() {
        for inputEdge in GuardedBytes.Edge.allCases {
            for outputEdge in GuardedBytes.Edge.allCases {
                for count in Self.lengths {
                    let bytes = (0 ..< count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }
                    GuardedBytes.with(bytes, against: inputEdge) { input in
                        // The output holds exactly the most the kernel may write, so one byte more crashes.
                        GuardedBytes.with([UInt8](repeating: 0, count: count / 3 * 4), against: outputEdge) { fast in
                            GuardedBytes.with([UInt8](repeating: 0, count: count / 3 * 4), against: outputEdge) {
                                slow in
                                let consumed = encode(input, count, fast, backend: .fastest)
                                let reference = encode(input, count, slow, backend: .scalar)
                                #expect(consumed % 3 == 0 && consumed <= count)
                                #expect(reference == count / 3 * 3)
                                // The kernel's blocks are a prefix of the reference's output.
                                #expect((0 ..< consumed / 3 * 4).allSatisfy { fast[$0] == slow[$0] }, "length \(count)")
                            }
                        }
                    }
                }
            }
        }
    }

    @Test func `decoding stays inside an input and an output that end at a guard page`() {
        for inputEdge in GuardedBytes.Edge.allCases {
            for outputEdge in GuardedBytes.Edge.allCases {
                for count in Self.lengths {
                    let bads: [Int?] = [nil, count - 1, count / 2]
                    for badAt in bads {
                        checkGuardedDecode(count: count, badAt: badAt, inputEdge: inputEdge, outputEdge: outputEdge)
                    }
                }
            }
        }
    }

    /// One case of the guarded decode test, kept apart so that each body stays quick to type-check.
    private func checkGuardedDecode(
        count: Int,
        badAt: Int?,
        inputEdge: GuardedBytes.Edge,
        outputEdge: GuardedBytes.Edge
    ) {
        var text: [UInt8] = (0 ..< count).map { (index: Int) -> UInt8 in Self.symbols[(index &* 7 &+ 3) % 64] }
        let bad: Int? = badAt.flatMap { (at: Int) -> Int? in at >= 0 && at < count ? at : nil }
        if let bad { text[bad] = UInt8(ascii: "!") }
        let outputCount: Int = count / 4 * 3
        GuardedBytes.with(text, against: inputEdge) { input in
            GuardedBytes.with([UInt8](repeating: 0, count: outputCount), against: outputEdge) { fast in
                GuardedBytes.with([UInt8](repeating: 0, count: outputCount), against: outputEdge) { slow in
                    let consumed: Int = decode(input, count, fast, backend: .fastest)
                    let reference: Int = decode(input, count, slow, backend: .scalar)
                    #expect(
                        consumed % 4 == 0 && consumed <= reference,
                        "length \(count) bad \(String(describing: bad))"
                    )
                    let decoded: Int = consumed / 4 * 3
                    var same = true
                    for index in 0 ..< decoded where fast[index] != slow[index] { same = false }
                    #expect(same)
                    if let bad { #expect(consumed <= bad) }
                }
            }
        }
    }

    @Test func `wrapped text stays inside an input and an output that end at a guard page`() {
        for edge in GuardedBytes.Edge.allCases {
            for width in [16, 64, 76] {
                for count in [0, 1, 47, 48, 57, 58, 114, 200, 1000] {
                    for crlf in [false, true] {
                        let bytes = (0 ..< count).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ 1) }
                        let lineBytes = width / 4 * 3
                        let lineCount = max(1, (count + lineBytes - 1) / lineBytes)
                        let capacity = (count + 2) / 3 * 4 + (lineCount - 1) * (crlf ? 2 : 1)
                        GuardedBytes.with(bytes, against: edge) { input in
                            GuardedBytes.with([UInt8](repeating: 0, count: capacity), against: edge) { output in
                                let encoded = Self.symbols.withUnsafeBufferPointer { table in
                                    AemiKernels.base64EncodeLines(
                                        table: table,
                                        tail: Self.tail,
                                        input: UnsafeBufferPointer(start: input, count: count),
                                        output: UnsafeMutableBufferPointer(start: output, count: capacity),
                                        width: width,
                                        crlf: crlf
                                    )
                                }
                                #expect(encoded.consumed % lineBytes == 0 && encoded.consumed <= count)
                                // Decode what was written, flush against the guard page again.
                                let text = Array(UnsafeBufferPointer(start: output, count: encoded.written))
                                GuardedBytes.with(text, against: edge) { source in
                                    GuardedBytes.with([UInt8](repeating: 0, count: encoded.consumed), against: edge) {
                                        target in
                                        let decoded = Self.lookup.withUnsafeBufferPointer { table in
                                            AemiKernels.base64DecodeLines(
                                                lookup: table,
                                                tail: Self.tail,
                                                input: UnsafeBufferPointer(start: source, count: text.count),
                                                output: UnsafeMutableBufferPointer(
                                                    start: target,
                                                    count: encoded.consumed
                                                ),
                                                width: width
                                            )
                                        }
                                        #expect(decoded.consumed == text.count && decoded.written == encoded.consumed)
                                        #expect((0 ..< decoded.written).allSatisfy { target[$0] == bytes[$0] })
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Calls that break the contract trap

    @Test func `a symbol table of the wrong size traps`() async {
        await #expect(processExitsWith: .failure) {
            let table = [UInt8](repeating: 65, count: 63)
            var out = [UInt8](repeating: 0, count: 64)
            let input = [UInt8](repeating: 1, count: 48)
            _ = table.withUnsafeBufferPointer { t in
                input.withUnsafeBufferPointer { i in
                    out.withUnsafeMutableBufferPointer { o in
                        AemiKernels.base64EncodeBlocks(table: t, tail: 0, input: i, output: o)
                    }
                }
            }
        }
    }

    @Test func `a reverse table of the wrong size traps`() async {
        await #expect(processExitsWith: .failure) {
            let table = [UInt8](repeating: 0, count: 128)
            var out = [UInt8](repeating: 0, count: 48)
            let input = [UInt8](repeating: 65, count: 64)
            _ = table.withUnsafeBufferPointer { t in
                input.withUnsafeBufferPointer { i in
                    out.withUnsafeMutableBufferPointer { o in
                        AemiKernels.base64DecodeBlocks(lookup: t, tail: 0, input: i, output: o)
                    }
                }
            }
        }
    }

    @Test func `an output one byte too small traps`() async {
        await #expect(processExitsWith: .failure) {
            let input = [UInt8](repeating: 1, count: 48)
            var out = [UInt8](repeating: 0, count: 63)
            _ = AemiKernelsBase64Tests.symbols.withUnsafeBufferPointer { t in
                input.withUnsafeBufferPointer { i in
                    out.withUnsafeMutableBufferPointer { o in
                        AemiKernels.base64EncodeBlocks(table: t, tail: 0, input: i, output: o)
                    }
                }
            }
        }
        await #expect(processExitsWith: .failure) {
            let input = [UInt8](repeating: 65, count: 64)
            var out = [UInt8](repeating: 0, count: 47)
            _ = AemiKernelsBase64Tests.lookup.withUnsafeBufferPointer { t in
                input.withUnsafeBufferPointer { i in
                    out.withUnsafeMutableBufferPointer { o in
                        AemiKernels.base64DecodeBlocks(lookup: t, tail: 0, input: i, output: o)
                    }
                }
            }
        }
    }

    @Test func `an output that overlaps the input traps`() async {
        await #expect(processExitsWith: .failure) {
            var buffer = [UInt8](repeating: 65, count: 128)
            buffer.withUnsafeMutableBufferPointer { b in
                let input = UnsafeBufferPointer(rebasing: b[0 ..< 64])
                let output = UnsafeMutableBufferPointer(rebasing: b[16 ..< 64])
                _ = AemiKernelsBase64Tests.lookup.withUnsafeBufferPointer { t in
                    AemiKernels.base64DecodeBlocks(lookup: t, tail: 0, input: input, output: output)
                }
            }
        }
    }

    @Test func `folding over a shifted copy of itself traps, and in place is allowed`() async {
        var inPlace = Array("HELLO, WORLD — in place".utf8)
        inPlace.withUnsafeMutableBufferPointer { b in
            AemiKernels.foldASCII(into: b.baseAddress!, from: UnsafePointer(b.baseAddress!), count: b.count)
        }
        #expect(String(decoding: inPlace, as: UTF8.self) == "hello, world — in place")
        await #expect(processExitsWith: .failure) {
            var buffer = [UInt8](repeating: 65, count: 100)
            buffer.withUnsafeMutableBufferPointer { b in
                AemiKernels.foldASCII(into: b.baseAddress! + 8, from: UnsafePointer(b.baseAddress!), count: 64)
            }
        }
    }

    @Test func `a Hamming scan with too small a corpus, output or an overflowing size traps`() async {
        await #expect(processExitsWith: .failure) {
            let query = [UInt8](repeating: 1, count: 16)
            let corpus = [UInt8](repeating: 2, count: 16 * 3 - 1)
            var out = [UInt32](repeating: 0, count: 3)
            query.withUnsafeBufferPointer { q in
                corpus.withUnsafeBufferPointer { c in
                    out.withUnsafeMutableBufferPointer {
                        AemiKernels.hammingScan(query: q, corpus: c, width: 16, count: 3, into: $0)
                    }
                }
            }
        }
        await #expect(processExitsWith: .failure) {
            let query = [UInt8](repeating: 1, count: 16)
            let corpus = [UInt8](repeating: 2, count: 48)
            var out = [UInt32](repeating: 0, count: 2)
            query.withUnsafeBufferPointer { q in
                corpus.withUnsafeBufferPointer { c in
                    out.withUnsafeMutableBufferPointer {
                        AemiKernels.hammingScan(query: q, corpus: c, width: 16, count: 3, into: $0)
                    }
                }
            }
        }
        await #expect(processExitsWith: .failure) {
            var byte: UInt8 = 0
            var distance: UInt32 = 0
            AemiKernels.hammingScan(query: &byte, corpus: &byte, width: 1 << 40, count: 1 << 40, into: &distance)
        }
    }
}

import AemiKernel
import Testing

extension ReferenceBase64 {
    /// Encodes through a bit string, then wraps naively.
    static func encode(_ input: [UInt8], _ options: Base64.Options) -> [UInt8] {
        let symbols = options.alphabet.symbols
        var bits: [Int] = []
        for byte in input { for shift in stride(from: 7, through: 0, by: -1) { bits.append(Int(byte >> shift) & 1) } }
        while bits.count % 6 != 0 { bits.append(0) }
        var text: [UInt8] = stride(from: 0, to: bits.count, by: 6)
            .map { start in
                symbols[bits[start ..< start + 6].reduce(0) { $0 << 1 | $1 }]
            }
        if options.padding != .forbidden { while text.count % 4 != 0 { text.append(UInt8(ascii: "=")) } }
        guard let width = options.lineLength.map({ max(1, $0) }) else { return text }
        let separator: [UInt8] = options.lineEnding == .lf ? [0x0A] : [0x0D, 0x0A]
        var wrapped: [UInt8] = []
        for start in stride(from: 0, to: text.count, by: width) {
            if start > 0 { wrapped += separator }
            wrapped += text[start ..< min(start + width, text.count)]
        }
        return wrapped
    }
}

extension Base64 {
    /// Encodes `input` into a `capacity`-byte window of a larger buffer. A failed encode must leave the
    /// whole buffer untouched; a successful one must not write past the window.
    @discardableResult
    static func encodeCanary(
        _ input: some Collection<UInt8>, capacity: Int, options: Options
    ) throws(EncodeError) -> (written: Int, window: [UInt8]) {
        var storage = [UInt8](repeating: canaryByte, count: capacity + 16)
        do {
            let written = try SpanAccess.write(&storage, first: capacity) { (span) throws(EncodeError) in
                try Base64.encode(input, into: &span, options: options)
            }
            Self.checkCanary(storage, capacity)
            return (written, Array(storage[..<capacity]))
        } catch {
            #expect(storage.allSatisfy { $0 == canaryByte }, "a failed encode must not write")
            throw error
        }
    }
}

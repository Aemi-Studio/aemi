import AemiKernel
import AemiTestKit
import Testing

/// A collection that hides its contiguous storage, forcing the generic (byte-by-byte) decode path.
struct NonContiguousBytes: Collection {
    let storage: [UInt8]
    var startIndex: Int { 0 }
    var endIndex: Int { storage.count }
    func index(after i: Int) -> Int { i + 1 }
    subscript(position: Int) -> UInt8 { storage[position] }
}

/// A deliberately naive decoder written from the specification rather than from the production state
/// machine: it classifies every byte first, then checks structure, then converts via a bit string.
enum ReferenceBase64 {
    static func decode(_ input: [UInt8], _ options: Base64.Options) -> [UInt8]? {
        let symbols = options.alphabet.symbols
        var sextets: [Int] = []
        var padCount = 0
        var line = 0
        var index = 0
        while index < input.count {
            let byte = input[index]
            index += 1
            if let value = symbols.firstIndex(of: byte) {
                guard padCount == 0 else { return nil }
                sextets.append(value)
                line += 1
            } else if byte == UInt8(ascii: "=") {
                guard options.padding != .forbidden else { return nil }
                padCount += 1
                line += 1
            } else {
                guard skip(byte, input, index, options.whitespace) else { return nil }
                if byte == 0x0D, options.whitespace == .skipLineBreaks { index += 1 }  // the LF that follows
                if byte == 0x0A || byte == 0x0D { line = 0 }
            }
            if options.whitespace != .reject, let limit = options.lineLength, line > max(1, limit) { return nil }
        }
        guard let bytes = convert(sextets, padCount: padCount, options: options) else { return nil }
        if let limit = options.maximumDecodedSize, bytes.count > max(0, limit) { return nil }
        return bytes
    }

    /// Whether `byte` (at `input[next - 1]`) is skippable under `policy`.
    private static func skip(_ byte: UInt8, _ input: [UInt8], _ next: Int, _ policy: Base64.WhitespacePolicy) -> Bool {
        switch policy {
            case .reject:
                return false
            case .skipLineBreaks:
                if byte == 0x0A { return true }
                return byte == 0x0D && next < input.count && input[next] == 0x0A
            case .skipAll:
                return [0x20, 0x09, 0x0A, 0x0B, 0x0C, 0x0D].contains(byte)
        }
    }

    private static func convert(_ sextets: [Int], padCount: Int, options: Base64.Options) -> [UInt8]? {
        let leftover = sextets.count % 4
        guard leftover != 1 else { return nil }
        switch options.padding {
            case .required where padCount == 0 && leftover != 0: return nil
            case .required, .optional:
                if padCount > 0 && padCount != (leftover == 0 ? 0 : 4 - leftover) { return nil }
            case .forbidden, .tolerated:
                break
        }
        var bits: [Int] = []
        for value in sextets { for shift in stride(from: 5, through: 0, by: -1) { bits.append((value >> shift) & 1) } }
        let whole = bits.count / 8
        if options.trailingBits == .canonical, bits[(whole * 8)...].contains(1) { return nil }
        return (0 ..< whole).map { byte in bits[byte * 8 ..< byte * 8 + 8].reduce(0) { $0 << 1 | $1 }.asByte }
    }
}

extension Int {
    fileprivate var asByte: UInt8 { UInt8(truncatingIfNeeded: self) }
}

/// Seeded option and input generators shared by the property, differential, and fuzz suites.
enum Base64Generators {
    static let presets: [Base64.Options] = [
        .strict, .urlSafe, .urlSafeNoPadding, .mime, .pem, .lenient
    ]

    /// A custom alphabet: the standard one permuted by `rng`.
    static func customAlphabet(_ rng: inout SeededRNG) -> Base64.AlphabetTable {
        var symbols = Base64.AlphabetTable.standard.symbols
        symbols.shuffle(using: &rng)
        guard let table = try? Base64.AlphabetTable(symbols: symbols) else { return .standard }
        return table
    }

    static func randomOptions(_ rng: inout SeededRNG) -> Base64.Options {
        var options = rng.pick(presets)
        switch rng.uniform(4) {
            case 0: options.alphabet = .urlSafe
            case 1: options.alphabet = customAlphabet(&rng)
            default: break
        }
        if rng.bool() { options.padding = rng.pick([.required, .optional, .forbidden, .tolerated]) }
        if rng.bool() { options.trailingBits = rng.pick([.canonical, .lenient]) }
        if rng.bool() { options.whitespace = rng.pick([.reject, .skipLineBreaks, .skipAll]) }
        if rng.bool() { options.lineLength = rng.pick([nil, 1, 4, 5, 8, 64, 76]) }
        if rng.bool() { options.lineEnding = rng.pick([.lf, .crlf]) }
        if rng.uniform(4) == 0 { options.maximumDecodedSize = rng.uniform(40) }
        return options
    }

    static func randomBytes(_ count: Int, _ rng: inout SeededRNG) -> [UInt8] {
        (0 ..< count).map { _ in rng.byte() }
    }

    /// Bytes that mostly look like Base64 (symbols, `=`, line breaks, spaces) with a few strays.
    static func randomText(_ count: Int, _ options: Base64.Options, _ rng: inout SeededRNG) -> [UInt8] {
        let symbols = options.alphabet.symbols
        return (0 ..< count)
            .map { _ in
                switch rng.uniform(20) {
                    case 0: return UInt8(ascii: "=")
                    case 1: return 0x0A
                    case 2: return 0x0D
                    case 3: return 0x20
                    case 4: return rng.byte()
                    default: return rng.pick(symbols)
                }
            }
    }
}

// MARK: - Span adapters
//
// `Array.span` / `Array.mutableSpan` need macOS 26; the codec's `Span` overloads run on the package's
// macOS 15 floor, so the tests build their spans from buffer pointers.

enum SpanAccess {
    static func read<R, E: Error>(
        _ array: [UInt8], _ body: (Span<UInt8>) throws(E) -> R
    ) throws(E) -> R {
        try array.withUnsafeBufferPointer { (buffer) throws(E) in
            try body(Span(_unsafeElements: buffer))
        }
    }

    /// Hands `body` a `MutableSpan` over the first `count` elements of `array` (all of them by default).
    static func write<R, E: Error>(
        _ array: inout [UInt8], first count: Int? = nil, _ body: (inout MutableSpan<UInt8>) throws(E) -> R
    ) throws(E) -> R {
        let window = count ?? array.count
        return try array.withUnsafeMutableBufferPointer { (buffer) throws(E) in
            var span = MutableSpan(_unsafeElements: UnsafeMutableBufferPointer(rebasing: buffer[..<window]))
            return try body(&span)
        }
    }
}

let canaryByte: UInt8 = 0xA5

extension Base64 {
    /// Decodes `input` into a `capacity`-byte window of a larger buffer and checks that nothing past the
    /// window was touched, whether or not the decode succeeded.
    @discardableResult
    static func decodeCanary(
        _ input: some Collection<UInt8>, capacity: Int, options: Options
    ) throws(DecodeError) -> (written: Int, window: [UInt8]) {
        var storage = [UInt8](repeating: canaryByte, count: capacity + 16)
        do {
            let written = try SpanAccess.write(&storage, first: capacity) { (span) throws(DecodeError) in
                try Base64.decode(input, into: &span, options: options)
            }
            Self.checkCanary(storage, capacity)
            return (written, Array(storage[..<capacity]))
        } catch {
            Self.checkCanary(storage, capacity)
            throw error
        }
    }

    static func checkCanary(_ storage: [UInt8], _ capacity: Int) {
        #expect(storage[capacity...].allSatisfy { $0 == canaryByte }, "wrote past the output window")
    }
}

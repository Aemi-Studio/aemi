extension Base64 {
    /// Why ``AlphabetTable/init(symbols:)`` rejected a custom alphabet.
    public enum AlphabetError: Error, Sendable, Hashable {
        /// The alphabet did not have exactly 64 symbols; the payload is the number supplied.
        case wrongSymbolCount(Int)
        /// A byte appeared more than once, which would make decoding ambiguous.
        case duplicateSymbol(UInt8)
        /// A byte outside printable ASCII (`0x21 ... 0x7E`), or the padding byte `=`. Whitespace and
        /// control bytes are excluded so a symbol can never be confused with a skipped line break.
        case unsupportedSymbol(UInt8)
    }

    /// A 64-symbol Base64 alphabet together with its reverse (byte → sextet) table.
    ///
    /// ``standard`` is RFC 4648 §4 (`+` `/`) and ``urlSafe`` is §5 (`-` `_`). A custom alphabet is
    /// built with ``init(symbols:)``, which validates it once so the codec never has to: exactly 64
    /// distinct printable-ASCII bytes, none of them `=`.
    public struct AlphabetTable: Sendable, Hashable {
        /// Sextet value (0–63) → symbol byte. Always 64 elements.
        let encodeTable: [UInt8]
        /// Byte → sextet value, or ``invalidSextet`` for a byte outside the alphabet. Always 256 elements.
        let decodeTable: [UInt8]

        /// The marker ``decodeTable`` holds for a byte that is not in the alphabet.
        static let invalidSextet: UInt8 = 0xFF

        /// RFC 4648 §4 (`A–Z a–z 0–9 + /`).
        public static let standard = AlphabetTable(
            validSymbols: Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8))

        /// RFC 4648 §5, the URL- and filename-safe form (`A–Z a–z 0–9 - _`).
        public static let urlSafe = AlphabetTable(
            validSymbols: Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8))

        /// The table for one of the two built-in ``Base64/Alphabet`` values.
        public init(_ alphabet: Alphabet) {
            switch alphabet {
                case .standard: self = .standard
                case .urlSafe: self = .urlSafe
            }
        }

        /// A custom alphabet: `symbols[i]` is the byte that stands for the sextet value `i`.
        ///
        /// - Throws: ``AlphabetError`` unless `symbols` holds exactly 64 distinct bytes, each printable
        ///   ASCII (`0x21 ... 0x7E`) and not `=`.
        /// - Complexity: O(1); the work is bounded by the 64-symbol limit.
        public init(symbols: some Collection<UInt8>) throws(AlphabetError) {
            guard symbols.count == 64 else { throw .wrongSymbolCount(symbols.count) }
            var seen = [Bool](repeating: false, count: 256)
            for byte in symbols {
                guard (0x21 ... 0x7E).contains(byte), byte != Base64.padByte else {
                    throw .unsupportedSymbol(byte)
                }
                guard !seen[Int(byte)] else { throw .duplicateSymbol(byte) }
                seen[Int(byte)] = true
            }
            self.init(validSymbols: Array(symbols))
        }

        /// The 64 symbol bytes, indexed by sextet value.
        public var symbols: [UInt8] { encodeTable }

        private init(validSymbols: [UInt8]) {
            var reverse = [UInt8](repeating: Self.invalidSextet, count: 256)
            for (value, byte) in validSymbols.enumerated() { reverse[Int(byte)] = UInt8(value) }
            self.encodeTable = validSymbols
            self.decodeTable = reverse
        }
    }
}
